package PVE::QemuServer::Machine;

# A Machine represents a qemu hardware configuration. This provides methods to
# add various types of hardware components, requested OS specific quirks, and
# is responsible for two things:
#   - Building a qemu command line to start a machine, and
#   - Checking and executing hotplug commands for already running machine.
# For hotplugging, a machine is first fully configured using the old
# (currently running) configuration, then we set a flag to tell the instance
# that it is actually running, then we execute the asme add/remove methods used
# for the initial configuration.
# TODO: all the remove_* methods and hotplugging functionality...

use strict;
use warnings;

use PVE::Tools;
use PVE::Network;
use PVE::INotify;
use PVE::QemuServer;
use PVE::QemuServer::Memory;
use PVE::QemuServer::Machine::i440fx;
use PVE::QemuServer::Machine::q35;
use PVE::QemuServer::Machine::arm_virt;

my $var_run_tmpdir = "/var/run/qemu-server";

my $kernel_has_vhost_net = -c '/dev/vhost-net';

sub qemu_cmd {
    return '/usr/bin/kvm';
    # FIXME: die "define me";
}

# Helper for nicer error messages ...
sub assert_empty_options($%) {
    my ($where, %options) = @_;
    my @keys = keys %options;
    return if !@keys;
    die "$where: unknown option: $keys[0]\n" if @keys == 1;
    die "$where: unknown options: ".join(', ', sort @keys)."\n";
}

sub create {
    my ($class, $vmid, $machine_type, $name, $hotplug) = @_;

    my $self;

    my $pxe;

    if (!defined($machine_type)) {
	# FIXME: This default is arch-dependent. We're assuming x86_64
	$self = PVE::QemuServer::Machine::i440fx->new();
    } elsif ($machine_type =~ /^(?:pc|pc(?:-i440fx)?-(\d+\.\d+)(\.pxe)?)$/) {
	$self = PVE::QemuServer::Machine::i440fx->new($1);
	$pxe = !!$2;
    } elsif ($machine_type =~ /^(?:q35|pc-q35-(\d+\.\d+)(\.pxe)?)$/) {
	die "TODO: q35 machine\n";
    } elsif ($machine_type =~ /^(?:arm-virt(?:-(\d+\.\d+))?)$/) {
	die "TODO: arm-virt machine\n";
    } else {
	die "unknown machine type: $machine_type\n";
    }

    # FIXME: this should be a parameter
    # Also FIXME: Should we add a method to load a Machine configuration from
    # qemu via qmp? Would ensure a working migration...
    $self->{running} = 0; # for hotplugging

    $self->{pxe} = $pxe;

    $self->{hotplug} = $hotplug;
    $self->{options}      //= {};

    $self->{buses}        //= {}; # to keep track of pci/scsi/... bus addresses
    $self->{objects}      //= {}; # generic qemu objects (iothreads, ...)
    $self->{chardevs}     //= {}; # local character device references
    $self->{drives}       //= {}; # disk file references
    $self->{disks}        //= {}; # qemu disk device end
    $self->{net_links}    //= {}; # tap/veth/... devices
    $self->{net}          //= {}; # qemu network device end
    $self->{devices}      //= {}; # generic devices
    $self->{globals}      //= {};
    $self->{rtc_opts}     //= {};

    $self->{cpu}          //= {};
    $self->{cpu}->{opts}  //= {};
    $self->{cpu}->{smp}   //= {};
    $self->{cpu}->{smp}->{sockets} //= 1;
    $self->{cpu}->{smp}->{cores} //= 1;
    $self->{cpu}->{smp}->{vcpus} //= 1;

    $self->{memory}       //= {};
    $self->{numa}         //= {};

    $self->{machine_opts} //= { accel => 'kvm' };
    $self->{iscsi}        //= {};

    $self->{vmid} = $vmid;
    $self->{name} = $name || "vm$vmid",
    # Since the configured machine type may include versions we store this
    # separately as well.
    $self->{machine_type} = $machine_type;

    $self->{volume_list} //= [];

    # Never add anything that fits into any of the above categories to this
    # array:
    $self->{args} //= [];

    return $self;
}

sub options2string(%) {
    my (%hash) = @_;
    my $str = '';
    foreach my $o (sort keys %hash) {
	my $v = $hash{$o};
	next if !defined($v);
	$str .= ',' if length($str);
	$str .= $o;
	$str .= "=$v" if length($v);
    }
    return $str;
}

sub check_hotplug {
    my ($self, $what) = @_;
    return 0 if !$self->{running};
    my $hotplug = $self->{hotplug};
    die "skip\n" if !$hotplug || !$hotplug->{$what};
    return 1;
}

sub no_hotplug {
    my ($self, $what) = @_;
    die "cannot change $what of a running VM\n" if $self->{running};
}

sub set_global {
    my ($self, $key, $value) = @_;
    $self->no_hotplug('globals');
    my $globals = ($self->{globals} //= {});
    $globals->{$key} = $value;
}

sub add_args {
    my ($self, @args) = @_;
    $self->no_hotplug('qemu args');
    push @{$self->{args}}, @args;
}

# Main device address method. This should return an address like
# "bus=pci.0,addr=0x01.0x02".
sub get_address {
    my ($self, $id) = @_;
    die "implement me";
}

sub add_cpu {
    my ($self, $id, $core, $socket, $thread) = @_;
    die "implement me";
}

sub network_device {
    my ($self, $type) = @_;
    # Eg. on arm-virt we translate virtio to virtio-net-device rather than
    # virtio-net-pci since we attach it to the virtio-mmio bus.
    die "implement me";
}

sub disk_device {
    my ($self, $type) = @_;
    # Eg. on arm-virt we use virtio-blk-device rather than virtio-blk-pci...
    die "implement me";
}

sub set_bios_type {
    my ($self, $type) = @_;
    die "implement me";
}

sub add_tablet {
    my ($self) = @_;
    # This is up to the machine as arm-virt also needs to add usb-kbd (FIXME: why?)
    die "implement me";
}

sub remove_tablet {
    my ($self) = @_;
    die "implement me";
}

sub add_host_pci_device {
    my ($self, $id, $host, $function, %options) = @_;
    die "implement me";
}

sub add_host_pcie_device {
    my ($self, $id, $host, $function, %options) = @_;
    die "implement me";
}

sub get_scsi_address {
    my ($self, $type, $index, $options) = @_;
    die "implement me";
}

sub get_sata_address {
    my ($self, $index) = @_;
    die "implement me";
}

sub add_ehci_controller {
    my ($self, $id) = @_;
    die "implement me";
}

sub add_uhci_controller {
    my ($self, $id) = @_;
    die "implement me";
}

sub add_xhci_controller {
    my ($self, $id) = @_;
    die "implement me";
}

sub get_network_rom {
    my ($self, $type) = @_;
    # Implement in subclass if required
    return undef;
}

sub set_cpu_type {
    my ($self, $type) = @_;
    $self->no_hotplug('cpu type');
    $self->{cpu}->{type} = $type;
}

sub no_hotplug_assign_or_fetch {
    my ($self, $what, $ref, $value_ref) = @_;
    if (defined($$value_ref)) {
	$self->no_hotplug($what);
	$$ref = $$value_ref;
    } else {
	$$value_ref = $$ref;
    }
}

sub set_smp {
    my ($self, $vcpus, $sockets, $cores) = @_;
    my $smp = $self->{cpu}->{smp};

    $self->no_hotplug_assign_or_fetch('sockets', \$smp->{sockets}, \$sockets);
    $self->no_hotplug_assign_or_fetch('cores',   \$smp->{cores},   \$cores);
    $smp->{maxcpus} = $sockets*$cores;

    if ($self->{hotplug}->{cpu}) {
	$smp->{vcpus} = 1;
	foreach my $i (2..$vcpus) {
	    my $cur_core = ($i-1) % $cores;
	    my $cur_socket = int(($i - $cur_core) / $cores);
	    $self->add_cpu("cpu$i", $cur_core, $cur_socket, 0);
	}
    } else {
	die "cpu hotplugging is not enabled for this VM\n" if $self->{running};
	$smp->{vcpus} = $vcpus;
    }
}

sub assert_empty_disk_slot {
    my ($self, $type, $index) = @_;

    my $dest = ($self->{disks}->{$type} //= {});

    die "disk slot $type $index already in use\n"
	if $dest->{$index};

    return $dest;
}

sub add_virtio_disk {
    my ($self, $index, $drivename, %options) = @_;

    my $dest = $self->assert_empty_disk_slot('virtio', $index);

    my $addr = $self->get_address("virtio$index");

    my $typename = $self->disk_device('virtio');

    my $cmd = "$typename,id=virtio$index,drive=$drivename,$addr";
    if (defined(my $bootindex = delete $options{bootindex})) {
	$cmd .= ",bootindex=$bootindex";
    }

    if (delete $options{iothread}) {
	my $iothread_id = "iothread-virtio-$index";
	$self->add_object('iothread', $iothread_id);
	$cmd .= ",iothread=$iothread_id";
    }

    assert_empty_options('virtio disk', %options);

    $dest->{$index} = $cmd;
}

sub add_scsi_disk {
    my ($self, $index, $drivename, $hwtype, %options) = @_;

    my $dest = $self->assert_empty_disk_slot('scsi', $index);

    my $addr = $self->get_scsi_address($hwtype, $index, \%options);

    my $drive = $self->{drives}->{$drivename};
    my $media = $drive->{media}//'drive';
    my $type = $media eq 'cdrom' ? 'cd' : 'hd';

    my $cmd = "scsi-$type,id=scsi$index,drive=$drivename,$addr";
    if (defined(my $bootindex = delete $options{bootindex})) {
	$cmd .= ",bootindex=$bootindex";
    }

    assert_empty_options('scsi disk', %options);

    $dest->{$index} = $cmd;
}

sub add_sata_disk {
    my ($self, $index, $drivename, %options) = @_;

    my $dest = $self->assert_empty_disk_slot('sata', $index);

    my $addr = $self->get_sata_address($index);

    my $cmd = "ide-drive,id=sata$index,drive=$drivename,$addr";
    if (defined(my $bootindex = delete $options{bootindex})) {
	$cmd .= ",bootindex=$bootindex";
    }

    assert_empty_options('sata disk', %options);

    $dest->{$index} = $cmd;
}

sub add_ide_disk {
    my ($self, $index, $drivename, %options) = @_;

    my $dest = $self->assert_empty_disk_slot('ide', $index);

    my $drive = $self->{drives}->{$drivename};
    my $media = $drive->{media}//'drive';
    my $type = $media eq 'cdrom' ? 'cd' : 'hd';
    
    my $busid = int($index / 2);
    my $unit = $index % 2;
    my $addr = "bus=ide.$busid,unit=$unit";

    my $cmd = "ide-$type,id=ide$index,drive=$drivename,$addr";
    if (defined(my $bootindex = delete $options{bootindex})) {
	$cmd .= ",bootindex=$bootindex";
    }

    assert_empty_options('ide disk', %options);

    $dest->{$index} = $cmd;
}

sub add_vga {
    my ($self, $type, %options) = @_;
    my $vgalist = ($self->{vga} //= []);
    my $id = scalar(@$vgalist);
    my $cmd;
    die "TODO: vga:serial" if $type =~ /^(?:serial\d+)$/; # FIXME:
    if (!$id) {
	# Virst video card uses the `-vga $type` option.
	$self->{vga} = $type;
    } else {
	# Additional cards are devices.
	my $addr = $self->get_address("vga$id");
	my $cmd = "$type,id=vga$id,$addr";
	$cmd .= ',' . options2string(%options) if %options;
    }
    push @$vgalist, $cmd;
}

sub add_smbios {
    my ($self, $type, $optstring) = @_;
    $self->no_hotplug('smbios');
    die "multiple smbios entries\n" if exists $self->{smbios};
    $self->{smbios} = "type=$type,$optstring";
}

sub add_network_device {
    my ($self, $type, $id, $mac, $netdev, %options) = @_;

    $type = $self->network_device($type);

    my $addr = $self->get_address($id);

    my $cmd = "$type,mac=$mac,netdev=$netdev,id=$id,$addr";

    if (defined(my $bootindex = delete $options{bootindex})) {
	$cmd .= ",bootindex=$bootindex";
    }

    if (defined(my $queues = delete $options{queues})) {
	warn "multiple queues are only supported on virtio network cards\n"
	    if $type ne 'virtio';

	# $queues rx vectors +
	# $queues tx vectors +
	# 1 config vector +
	# 1 control vq
	my $vectors = 2 + 2*$queues;
	$cmd .= ",vectors=$vectors,mq=on";
    }

    if (my $rom = $self->get_network_rom($type)) {
	$cmd .= ",romfile=$rom";
    }

    assert_empty_options('network device', %options);

    $self->{net}->{$id} = { command => $cmd };
}

sub add_tap_device {
    my ($self, $model, $id, $devname, $bridge, $hostname, $queues) = @_;

    die "interface name '$devname' is too long (must be no longer than 15 characters)\n"
	if length($devname) > 15;

    my $script = $self->{running} ? 'pve-bridge-hotplug' : 'pve-bridge';

    my $type = $bridge ? 'tap' : 'user';

    my $cmd = "type=$type,id=$id";
    if ($bridge) {
	$cmd .= ",ifname=$devname";
	$cmd .= ",script=/var/lib/qemu-server/$script";
	$cmd .= ",downscript=/var/lib/qemu-server/pve-bridgedown";
    } else {
	$cmd .= ",hostname=$hostname";
    }

    if ($model eq 'virtio') {
	$cmd .= ",vhost=on" if $kernel_has_vhost_net;
	$cmd .= ",queues=$queues" if $queues;
    } elsif ($queues) {
	warn "network card of type '$model' does not support queues\n";
    }

    $self->{net_links}->{$id} = {
	command => $cmd
    };
}

sub add_disk {
    my ($self, $interface, $index, $drivename, %options) = @_;
    if ($interface eq 'virtio') {
	# FIXME: we could warn here if $self->{drives}->{$drivename}->{discard}
	# is set to inform the user that virtio-blk does not support it.
	return $self->add_virtio_disk($index, $drivename, %options);
    } elsif ($interface eq 'scsi') {
	my $hwtype = delete $options{scsihw}
	    or die "missing scsi hardware type\n";
	return $self->add_scsi_disk($index, $drivename,, $hwtype, %options);
    } elsif ($interface eq 'sata') {
	return $self->add_sata_disk($index, $drivename, %options);
    } elsif ($interface eq 'ide') {
	return $self->add_ide_disk($index, $drivename, %options);
    }
    die "bad interface type: $interface\n";
}

my @RAW_DRIVE_OPTIONS = qw(
 aio cache
 cyls heads secs
 discard
 format
 iops iops_max iops_rd iops_rd_max iops_wr iops_wr_max
 media
 rerror
 snapshot
 trans
 werror
 detect-zeroes
 serial
);

sub add_drive {
    my ($self, $file, $id, %options) = @_;

    my %opt_copy = %options;

    my $drives = ($self->{drives} //= {});
    die "multiple drives of id $id\n" if exists($drives->{$id});

    my $iface = (delete($options{if}) // 'none');
    my $unit = delete $options{unit};

    # Some error checking: we don't want to add multiple units of the same
    # interface. (We're being overly cautious here.)
    if ($iface ne 'none' && defined($unit)) {
	my $ifhash = ($self->{ifaces}->{$iface} //= {});
	die "interface $iface already has a unit $unit\n"
	    if exists($ifhash->{$unit});
	$ifhash->{$unit} = 1;
    }

    my $cmd = "id=$id,if=$iface";
    $cmd .= ",unit=$unit" if defined($unit);
    my $media = $options{media};
    foreach my $key (@RAW_DRIVE_OPTIONS) {
	my $opt = delete $options{$key};
	next if !defined($opt);
	if (length($opt)) {
	    $cmd .= ",$key=$opt";
	} else {
	    $cmd .= ",$key";
	}
    }
    assert_empty_options('drive options', %options);

    if ($file) {
	$cmd .= ",file=$file";
    } elsif ($media && $media ne 'cdrom') {
	die "drive $id has no file and is not a cdrom\n";
    }

    $drives->{$id} = { file => $file, command => $cmd, %opt_copy };
}

sub add_pflash {
    my ($self, $unit, $file, $format, $readonly, $id) = @_;

    $self->no_hotplug('pflash');

    $id //= "pflash$unit";
    $self->add_drive($file, $id,
		     if => 'pflash',
		     unit => $unit,
		     format => $format,
		     readonly => ($readonly ? '' : undef));
}

sub add_chardev {
    my ($self, $type, $id, %options) = @_;
    my $cmd = "$type,id=$id";
    $cmd .= ',' . options2string(%options) if %options;
    $self->{chardevs}->{$id} = {
	type => $type,
	id => $id,
	command => $cmd,
	%options
    };
}

sub add_device_direct {
    my ($self, $type, $id, %options) = @_;
    die "device without id not allowed (type=$type)\n" if !defined $id;

    my $devices = ($self->{devices} //= {});
    my $cmd = $type;
    $cmd .= ",id=$id" if defined($id);
    $cmd .= ',' . options2string(%options) if %options;

    $devices->{$id} = {
	type => $type,
	id => $id,
	command => $cmd,
	%options
    };
}

sub add_device {
    my ($self, $type, $id, %options) = @_;

    my $devices = ($self->{devices} //= {});

    my $addr = $self->get_address($id);
    my $cmd = "$type,id=$id,$addr";
    $cmd .= ',' . options2string(%options) if %options;

    $devices->{$id} = {
	type => $type,
	id => $id,
	command => $cmd,
	%options
    };
}

sub add_object {
    my ($self, $type, $id, %options) = @_;

    my $objects = ($self->{objects} //= {});

    my $cmd = "$type,id=$id";
    $cmd .= ',' . options2string(%options) if %options;

    $objects->{$id} = {
	type => $type,
	id => $id,
	command => $cmd,
	%options
    };
}

sub add_vmgenid {
    my ($self, $vmgenid) = @_;

    return $self->add_device('vmgenid', 'vmgenid', guid => $vmgenid);
}

sub add_serial_chardev {
    my ($self, $id, $chardev, %options) = @_;
    $self->add_device($self->serial_device, $id, chardev => $chardev, %options);
}

sub add_serial_socket {
    my ($self, $id, $socket) = @_;
    $self->add_chardev('socket', $id, path => $socket, server => '', nowait => '');
    return $self->add_serial_chardev($id, $id);
}

sub add_serial_device {
    my ($self, $id, $devpath) = @_;
    $self->add_chardev('tty', $id, path => $devpath);
    return $self->add_serial_chardev($id, $id);
}

sub add_serial {
    my ($self, $id, $type, $path) = @_;
    return $self->add_serial_socket($id, $path) if $type eq 'socket';
    return $self->add_serial_device($id, $path) if $type eq 'device';
    die "unknown serial device connection type: $type\n";
}

sub add_parallel_chardev {
    my ($self, $id, $chardev, %options) = @_;
    $self->add_device($self->parallel_device, $id, chardev => $chardev, %options);
}

sub add_parallel_tty {
    my ($self, $id, $devttypath) = @_;
    $self->add_chardev('tty', $id, path => $devttypath);
    return $self->add_parallel_chardev($id);
}

sub add_parallel_parport {
    my ($self, $id, $devportpath) = @_;
    $self->add_chardev('parport', $id, path => $devportpath);
    return $self->add_parallel_chardev($id);
}

sub add_parallel {
    my ($self, $id, $type, $path) = @_;
    return $self->add_parallel_tty($id, $path) if $type eq 'tty';
    return $self->add_parallel_parport($id, $path) if $type eq 'parport';
    die "unknown parallel device type $type for path $path\n";
}

sub add_spice {
    my ($self) = @_;

    $self->no_hotplug('spice');

    return if exists $self->{spice_port};

    my $nodename = PVE::INotify::nodename();
    my $pfamily = PVE::Tools::get_host_address_family($nodename);
    $self->{spice_port} = PVE::Tools::next_spice_port($pfamily);

    $self->add_chardev('spicevmc', 'vdagent', name => 'vdagent');
    my $addr = $self->get_address('spice');
    $self->add_virtio_serial_bus('spice', 'spice.0');
    $self->add_device_direct('virtserialport', undef, chardev => 'vdagent',
			     name => 'com.redhat.spice.0',
			     bus => 'spice.0', nr => 0);
}

sub add_agent {
    my ($self) = @_;

    $self->no_hotplug('agent socket');

    return if exists $self->{devices}->{qga0};
    my $socket = PVE::QemuServer::qmp_socket($self->{vmid}, 1);

    $self->add_chardev('socket', 'qga0', path => $socket, server => '', nowait => '');
    $self->add_virtio_serial_bus('qga0', 'qga0');
    $self->add_device_direct('virtserialport', 'pve-qga0', chardev => 'qga0',
			     name => 'org.qemu.guest_agent.0',
			     bus => 'qga0.0', nr => 0);
}

sub set_iscsi_opts {
    my ($self, %opts) = @_;

    $self->no_hotplug('iscsi options');

    my $iscsi = $self->{iscsi};
    $iscsi->{$_} = $opts{$_} foreach keys %opts;
}

sub set_rtc_opts {
    my ($self, %opts) = @_;

    $self->no_hotplug('rtc options');

    my $rf = $self->{rtc_opts};
    $rf->{$_} = $opts{$_} foreach keys %opts;
}

sub set_machine_opts {
    my ($self, %opts) = @_;

    $self->no_hotplug('machine options');

    my $mf = $self->{machine_opts};
    $mf->{$_} = $opts{$_} foreach keys %opts;
}

sub disable_kvm {
    my ($self) = @_;

    $self->no_hotplug('accelerator');

    $self->set_machine_opts(accel => 'tcg');
}

sub set_cpu_opts {
    my ($self, %opts) = @_;

    $self->no_hotplug('cpu options');

    my $co = $self->{cpu}->{opts};
    $co->{$_} = $opts{$_} foreach keys %opts;
}

# General options which require some checking and enable different behavior
# later on. These should be set early.
sub set_option {
    my ($self, $option, $new) = @_;

    $self->no_hotplug('generic options');

    my $opts = $self->{options};
    my $old = delete $opts->{$option};
    if ($new) {
	$opts->{$option} = $new;
    }

    eval {
	if ($opts->{hugepages} && !$opts->{numa}) {
	    die "NUMA needs to be enabled to use hugepages\n";
	}
	# Any more checks?
    };
    if ($@) {
	$opts->{$option} = $old; # Revert the change
	die $@;
    }
}

sub set_memory {
    my ($self, $size, %opts) = @_;
    $self->{memory}->{size} = $size;
    $self->set_memory_opts(%opts);
}

sub set_memory_opts {
    my ($self, %opts) = @_;

    $self->no_hotplug('memory options');

    my $mem = $self->{memory};
    $mem->{$_} = $opts{$_} foreach keys %opts;
}

sub add_memory_object {
    my ($self, $id, $memory) = @_;

    my $memdev_type;
    my %memdev_options = ( size => "${memory}M" );

    if (my $hugepages = $self->{options}->{hugepages}) {
	$memdev_type = 'memory-backend-file';
	my $hugepages_size = PVE::QemuServer::Memory::hugepages_size($hugepages, $memory);
	$memdev_options{'mem-path'} = hugepages_mount_path($hugepages_size);
	$memdev_options{prealloc} = 'yes';
	$memdev_options{share} = 'on';
    } else {
	$memdev_type = 'memory-backend-ram';
    }
    $self->add_object($memdev_type, $id, %memdev_options);
}

sub add_dimm {
    my ($self, $id, $numa_node_id, $memory) = @_;
    my $numa = $self->{numa} or die "No numa nodes found\n";
    die "No such numa node id: $numa_node_id\n" if !exists $numa->{$numa_node_id};

    my $memdev_id = "mem-dimm$id";
    $self->add_memory_object($memdev_id, $memory);
    $self->add_device_direct('pc-dimm', "dimm$id", memdev => $memdev_id, node => $numa_node_id);
}

sub add_numa_node {
    my ($self, $index, $cpu_rangelist, $memory) = @_;

    $self->no_hotplug('numa node count');

    my $cpulist = join(',cpus=',
		  map {
		      my ($beg, $end) = @$_;
		      defined($end) ? "$beg-$end" : $beg
		  }
		  @$cpu_rangelist);

    die "No cpus specified in numa node numa$index\n"
	if !length($cpulist);

    my $memdev_id = "ram-node$index";
    $self->add_memory_object($memdev_id, $memory);

    my $numa = $self->{numa};
    my $cmd = "node,nodeid=$index,cpus=$cpulist,memdev=$memdev_id";
    $numa->{$index} = {
	memdev => "ram-node$index",
	cpus => $cpu_rangelist,
	command => $cmd,
	memory => $memory,
    };
}

sub check_memory {
    my ($self) = @_;
    my $numa = $self->{numa};
    my $numa_memory = 0;
    foreach my $id (keys %$numa) {
	$numa_memory += $numa->{$id}->{memory};
    }
    if ($numa_memory && $numa_memory != $self->{memory}->{size}) {
	die "Total NUMA node memory must be equal to the amount of static memory\n";
    }
}

sub add_balloon {
    my ($self) = @_;
    return if exists$self->{devices}->{balloon0};

    my $addr = $self->get_address('balloon0');
    $self->add_device($self->balloon_device, "balloon0");
}

sub add_watchdog {
    my ($self, $model) = @_;
    $model //= 'i6300esb';
    $self->add_device($model, 'watchdog');
}

sub add_usb_spice_redirection {
    my ($self, $id) = @_;

    $self->no_hotplug('usb spice redirection');

    $self->add_ehci_controller('ehci');
    my $chardev = "usbredirchardev$id";
    $self->add_chardev('spicevmc', $chardev, name => 'usbredir');
    $self->add_device_direct('usb-redir', "usbredirdev$id",
	chardev => $chardev,
	bus => 'ehci.0');
}

sub add_usb_controller {
    my ($self, $type) = @_;
    if ($type eq 'ehci') {
	$self->add_ehci_controller('ehci');
    } elsif ($type eq 'xhci') {
	$self->add_xhci_controller('xhci');
    } else {
	die "bad usb bus: $type\n";
    }
}

sub add_usb_device {
    my ($self, $id, $usb_bus, $vendorid, $productid) = @_;
    $self->add_usb_controller($usb_bus);
    $self->add_device_direct('usb-host', $id,
	vendorid => "0x$vendorid",
	productid => "0x$productid",
	bus => "${usb_bus}.0");
}

sub add_usb_host_port {
    my ($self, $id, $usb_bus, $hostbus, $hostport) = @_;
    $self->add_usb_controller($usb_bus);
    $self->add_device_direct('usb-host', $id,
	hostbus => $hostbus,
	hostport => $hostport,
	bus => "${usb_bus}.0");
}

sub to_command {
    my ($self) = @_;

    my $vmid = $self->{vmid};

    my $mon_qmp = PVE::QemuServer::qmp_socket($vmid);

    my $machine = $self->{machine};
    my $machine_opts = options2string(%{$self->{machine_opts}});
    $machine .= ',' . $machine_opts if length($machine_opts);

    my $cmd = [
	$self->qemu_cmd, '-daemonize', '-nodefaults',
	'-id', $vmid,
	'-name', $self->{name},
	'-pidfile', PVE::QemuServer::pidfile_name($vmid),
	'-machine', $machine,
	'-chardev', "socket,id=qmp,server,nowait,path=$mon_qmp",
	'-mon', 'chardev=qmp,mode=control',
    ];

    my $add_device_hash = sub {
	my ($devices, $is_hash, $arg) = @_;
	return if !$devices;
	$arg //= '-device';
	foreach my $id (sort keys %$devices) {
	    my $dev = $devices->{$id};
	    next if $is_hash && $dev->{internal};
	    $dev = $dev->{command} if $is_hash;
	    die "no command defined for $id\n" if !defined($dev);
	    push @$cmd, $arg, $dev if defined($dev) && length($dev);
	}
    };

    my $iscsi = options2string(%{$self->{iscsi}});
    push @$cmd, '-iscsi', $iscsi if length($iscsi);

    my $smp_opts = $self->{cpu}->{smp} or die "missing smp options";
    my $smp = $smp_opts->{vcpus};
    foreach my $opt (qw(sockets cores maxcpus)) {
	die "missing smp options" if !defined($smp_opts->{$opt});
	$smp .= ",$opt=$smp_opts->{$opt}";
    }
    push @$cmd, '-smp', $smp;

    my $cpu = $self->{cpu}->{type} // 'kvm64';
    my $cpu_opts = options2string(%{$self->{cpu}->{opts}});
    $cpu .= ",$cpu_opts" if length($cpu_opts);
    push @$cmd, '-cpu', $cpu;

    # FIXME: DEBUG: {{{
	my %memopts = %{$self->{memory}};
	my $mem = delete $memopts{size};
        my $memextra = options2string(%memopts);
	$mem .= ",$memextra" if length($memextra);
    # }}} else {{{
    #   my $mem = options2string(%{$self->{memory}});
    #   die "no memory configured\n" if !length($mem);
    # }}}
    die "missing memory options" if !defined($mem);
    push @$cmd, '-m', $mem;

    if (my $numa = $self->{numa}) {
	$add_device_hash->($numa, 1, '-numa');
    }

    if (defined(my $spice_port = $self->{spice_port})) {
	my @nodeaddrs = PVE::Tools::getaddrinfo_all('localhost', family => $pfamily);
	die "failed to get an ip address of type $pfamily for 'localhost'\n" if !@nodeaddrs;
	my $localhost = PVE::Network::addr_to_ip($nodeaddrs[0]->{addr});
	push @$cmd, '-spice', "tls-port=${spice_port},addr=$localhost,tls-ciphers=HIGH,seamless-migration=on";
    }

    if (my $smbios = $self->{smbios}) {
	push @$cmd, '-smbios', $smbios;
    }

    $add_device_hash->($self->{drives}, 1, '-drive');
    $add_device_hash->($self->{chardevs}, 1, '-chardev');

    $add_device_hash->($self->{buses}, 1);

    if (defined(my $vga = $self->{vga})) {
	push @$cmd, '-vga', $vga;
	my $socket = PVE::QemuServer::vnc_socket($self->{vmid});
	push @$cmd, '-vnc', "unix:$socket,x509,password";
    } else {
	push @$cmd, '-nographic';
    }

    $add_device_hash->($self->{devices}, 1);
    $add_device_hash->($self->{objects}, 1, '-object');

    if (my $disktypes = $self->{disks}) {
	foreach my $type (sort keys %$disktypes) {
	    $add_device_hash->($disktypes->{$type});
	}
    }

    $add_device_hash->($self->{net_links}, 1, '-netdev');
    $add_device_hash->($self->{net}, 1);

    if (my $globals = $self->{globals}) {
	foreach my $name (sort keys %$globals) {
	    push @$cmd, '-global', "$name=$globals->{$name}";
	}
    }

    my $rtc_opts = $self->{rtc_opts};
    my $rtc = options2string(%$rtc_opts);
    push @$cmd, '-rtc', $rtc if length($rtc);

    push @$cmd, @{$self->{args}};

    return wantarray
	? ($cmd, $self->{volume_list}, $self->{spice_port})
	: $cmd;
}

1;
