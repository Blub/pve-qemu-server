package PVE::QemuServer::Machine::i440fx;

use strict;
use warnings;

use base 'PVE::QemuServer::Machine';

# device kvmvapic
# device kvmclock
# device fw_cfg_io
# device hpet
# device kvm-ioapic
# device i440FX-pcihost {
#   bus pci.0 {
#     00.0: device i440FX: host bridge
#     01.0: device PIIX3: ISA bridge {
#       bus isa.0 {
#         device kvm-i8259
#         device kvm-i8259
#         device mv146818rtc
#         device kvm-pit
#         device isa-pcspk
#         device i8042
#         device vmport
#         device vmmouse
#         device port92
#         device i8257
#         device i8257
#         device isa-fdc: floppy controller
#         <isa-serials etc.>
#       }
#     }
#     01.1: device piix3-ide: IDE controller {
#       bus ide.{0..3}
#     }
#     01.3: device PIIX4_PM: Bridge {
#       bus i2c {
#         80..87: device smbus-eeprom
#       }
#     }
#     02.0: device VGA
#     rest open
#   }
# }

# Maps our internal device names (based on their name in the config) to
# an address.
my $pci_devices = {
    uhci           => { bus => 'pci.0', addr => 1, minor => 2 },
    #addr2 : first videocard
    balloon0       => { bus => 'pci.0', addr => 3 },
    watchdog       => { bus => 'pci.0', addr => 4 },
    scsihw0        => { bus => 'pci.0', addr => 5 },
    'pci.3'        => { bus => 'pci.0', addr => 5 }, #can also be used for virtio-scsi-single bridge
    scsihw1        => { bus => 'pci.0', addr => 6 },
    ahci0          => { bus => 'pci.0', addr => 7 },
    qga0           => { bus => 'pci.0', addr => 8 },
    spice          => { bus => 'pci.0', addr => 9 },
    virtio0        => { bus => 'pci.0', addr => 10 },
    virtio1        => { bus => 'pci.0', addr => 11 },
    virtio2        => { bus => 'pci.0', addr => 12 },
    virtio3        => { bus => 'pci.0', addr => 13 },
    virtio4        => { bus => 'pci.0', addr => 14 },
    virtio5        => { bus => 'pci.0', addr => 15 },
    hostpci0       => { bus => 'pci.0', addr => 16 },
    hostpci1       => { bus => 'pci.0', addr => 17 },
    net0           => { bus => 'pci.0', addr => 18 },
    net1           => { bus => 'pci.0', addr => 19 },
    net2           => { bus => 'pci.0', addr => 20 },
    net3           => { bus => 'pci.0', addr => 21 },
    net4           => { bus => 'pci.0', addr => 22 },
    net5           => { bus => 'pci.0', addr => 23 },
    vga1           => { bus => 'pci.0', addr => 24 },
    vga2           => { bus => 'pci.0', addr => 25 },
    vga3           => { bus => 'pci.0', addr => 26 },
    hostpci2       => { bus => 'pci.0', addr => 27 },
    hostpci3       => { bus => 'pci.0', addr => 28 },
    # pci0.0x1d: addr29 : usb-host (pve-usb.cfg)
    'pci.1'        => { bus => 'pci.0', addr => 30 },
    'pci.2'        => { bus => 'pci.0', addr => 31 },
    'net6'         => { bus => 'pci.1', addr => 1 },
    'net7'         => { bus => 'pci.1', addr => 2 },
    'net8'         => { bus => 'pci.1', addr => 3 },
    'net9'         => { bus => 'pci.1', addr => 4 },
    'net10'        => { bus => 'pci.1', addr => 5 },
    'net11'        => { bus => 'pci.1', addr => 6 },
    'net12'        => { bus => 'pci.1', addr => 7 },
    'net13'        => { bus => 'pci.1', addr => 8 },
    'net14'        => { bus => 'pci.1', addr => 9 },
    'net15'        => { bus => 'pci.1', addr => 10 },
    'net16'        => { bus => 'pci.1', addr => 11 },
    'net17'        => { bus => 'pci.1', addr => 12 },
    'net18'        => { bus => 'pci.1', addr => 13 },
    'net19'        => { bus => 'pci.1', addr => 14 },
    'net20'        => { bus => 'pci.1', addr => 15 },
    'net21'        => { bus => 'pci.1', addr => 16 },
    'net22'        => { bus => 'pci.1', addr => 17 },
    'net23'        => { bus => 'pci.1', addr => 18 },
    'net24'        => { bus => 'pci.1', addr => 19 },
    'net25'        => { bus => 'pci.1', addr => 20 },
    'net26'        => { bus => 'pci.1', addr => 21 },
    'net27'        => { bus => 'pci.1', addr => 22 },
    'net28'        => { bus => 'pci.1', addr => 23 },
    'net29'        => { bus => 'pci.1', addr => 24 },
    'net30'        => { bus => 'pci.1', addr => 25 },
    'net31'        => { bus => 'pci.1', addr => 26 },
    'xhci'         => { bus => 'pci.1', addr => 27 },
    'virtio6'      => { bus => 'pci.2', addr => 1 },
    'virtio7'      => { bus => 'pci.2', addr => 2 },
    'virtio8'      => { bus => 'pci.2', addr => 3 },
    'virtio9'      => { bus => 'pci.2', addr => 4 },
    'virtio10'     => { bus => 'pci.2', addr => 5 },
    'virtio11'     => { bus => 'pci.2', addr => 6 },
    'virtio12'     => { bus => 'pci.2', addr => 7 },
    'virtio13'     => { bus => 'pci.2', addr => 8 },
    'virtio14'     => { bus => 'pci.2', addr => 9 },
    'virtio15'     => { bus => 'pci.2', addr => 10 },
    'virtioscsi0'  => { bus => 'pci.3', addr => 1 },
    'virtioscsi1'  => { bus => 'pci.3', addr => 2 },
    'virtioscsi2'  => { bus => 'pci.3', addr => 3 },
    'virtioscsi3'  => { bus => 'pci.3', addr => 4 },
    'virtioscsi4'  => { bus => 'pci.3', addr => 5 },
    'virtioscsi5'  => { bus => 'pci.3', addr => 6 },
    'virtioscsi6'  => { bus => 'pci.3', addr => 7 },
    'virtioscsi7'  => { bus => 'pci.3', addr => 8 },
    'virtioscsi8'  => { bus => 'pci.3', addr => 9 },
    'virtioscsi9'  => { bus => 'pci.3', addr => 10 },
    'virtioscsi10' => { bus => 'pci.3', addr => 11 },
    'virtioscsi11' => { bus => 'pci.3', addr => 12 },
    'virtioscsi12' => { bus => 'pci.3', addr => 13 },
    'virtioscsi13' => { bus => 'pci.3', addr => 14 },
    'virtioscsi14' => { bus => 'pci.3', addr => 15 },
    'virtioscsi15' => { bus => 'pci.3', addr => 16 },
    'virtioscsi16' => { bus => 'pci.3', addr => 17 },
    'virtioscsi17' => { bus => 'pci.3', addr => 18 },
    'virtioscsi18' => { bus => 'pci.3', addr => 19 },
    'virtioscsi19' => { bus => 'pci.3', addr => 20 },
    'virtioscsi20' => { bus => 'pci.3', addr => 21 },
    'virtioscsi21' => { bus => 'pci.3', addr => 22 },
    'virtioscsi22' => { bus => 'pci.3', addr => 23 },
    'virtioscsi23' => { bus => 'pci.3', addr => 24 },
    'virtioscsi24' => { bus => 'pci.3', addr => 25 },
    'virtioscsi25' => { bus => 'pci.3', addr => 26 },
    'virtioscsi26' => { bus => 'pci.3', addr => 27 },
    'virtioscsi27' => { bus => 'pci.3', addr => 28 },
    'virtioscsi28' => { bus => 'pci.3', addr => 29 },
    'virtioscsi29' => { bus => 'pci.3', addr => 30 },
    'virtioscsi30' => { bus => 'pci.3', addr => 31 },

    'serial0' => { bus => 'isa.0' }
};

# FIXME: return '/usr/bin/qemu-system-x86_64';
sub qemu_cmd        { return '/usr/bin/kvm'; }
sub balloon_device  { return 'virtio-balloon-pci' }
sub serial_device   { return 'isa-serial' }
sub parallel_device { return 'isa-parallel' }

sub new {
    my ($class, $version) = @_;
    $version = "-i440fx-$version" if defined($version);

    my $self = {
	machine => defined($version) ? "pc$version" : 'pc',
	arch => 'x86_64', # used for cpu devices
	buses => {
	    'pci.0' => {
		internal => 1,
		slot_property => 'addr',
		slots => 0x20,
	    },
	    'isa.0' => {
		internal => 1,
		# serial devices go here
	    },
	},
	args => [
	    '-boot', 'menu=on,strict=on,reboot-timeout=1000,splash=/usr/share/qemu-server/bootsplash.jpg',
	],
    };
    $self = bless $self, $class;

    # We always add a piix3-usb-uhci device
    $self->add_uhci_controller('uhci');

    # We always add pci.1 and pci.2 since on-demand + hot-unplugging otherwise
    # easily breaks migration (unplug the only device found on pci.2 and the
    # command on the remote side won't include pci.2 but the running qemu still
    # has it => hardware mismatch)
    $self->add_pci_bus(1);
    $self->add_pci_bus(2);

    return $self;
}

# We create pci.1 and pci.2 on demand. Any other bus needs to be created
# explicitly currently.
sub get_address {
    my ($self, $id) = @_;
    my $res = '';
    my $dev = $pci_devices->{$id};
    die "no address available for device $id\n" if !$dev;
    my $bus = $dev->{bus};
    my $addr = $dev->{addr};
    my $minor = $dev->{minor};

    my $buses = $self->{buses};
    my $desc = $buses->{$bus};
    if (!$desc) {
	if ($bus =~ /^pci\.(\d+)$/) {
	    $desc = $self->add_pci_bus($1);
	}
	die "no such bus: $bus\n" if !$desc;
    }

    $res = sprintf('bus=%s', $bus);
    if ($desc->{slot_property}) {
	$res .= sprintf(',%s=0x%x', $desc->{slot_property}, $addr);
	$res .= sprintf('.0x%x', $minor) if defined($minor);
    }
    return $res;
}

sub add_bus_generic {
    my ($self, $device_type, $id, $busname,
        $slotprop, $slotcount, %options) = @_;

    my $buses = $self->{buses};
    if (my $bus = $buses->{$busname}) {
	return $bus;
    }

    my $addr = $self->get_address($id);

    my $cmd = "$device_type,id=$id,$addr";
    foreach my $opt (sort keys %options) {
	$cmd .= ",$opt=$options{$opt}";
    }
    my $bus = {
	slot_property => $slotprop,
	slots => $slotcount,
	command => $cmd,
    };

    $buses->{$busname} = $bus;

    return $bus;
}

sub add_pci_bus {
    my ($self, $id) = @_;
    return $self->add_bus_generic('pci-bridge', "pci.$id", "pci.$id",
				  'addr', 0x20,
				  chassis_nr => $id);
}

sub add_virtio_serial_bus {
    my ($self, $id, $busname) = @_;
    return $self->add_bus_generic('virtio-serial', $id, $busname,
				  'nr', 30);
}

sub add_cpu {
    my ($self, $id, $core, $socket, $thread) = @_;

    my $cpu = $self->{cpu}->{type};
    die "cpu type must be defined before adding cpu devices\n" if !$cpu;
    my $arch = $self->{arch};
    $self->add_device_direct("$cpu-$arch-cpu", $id,
			     'socket-id' => $socket,
			     'core-id' => $core,
			     'thread-id' => $thread);
}

# Pull in the helper
sub assert_empty_options($%) {
    PVE::QemuServer::Machine::assert_empty_options(@_);
}

sub disk_device {
    my ($self, $type) = @_;
    return 'virtio-blk-pci' if $type eq 'virtio';
    die "unhandled disk type: $type\n";
}

sub get_scsi_address {
    my ($self, $type, $index, $options) = @_;

    my $buses = $self->{buses};

    if ($type eq 'virtio-scsi-single') {
	my $id = "virtioscsi$index";
	my $iothread = delete $options->{iothread};

	if (!exists($buses->{$id})) {
	    my $addr = $self->get_address($id);
	    my $cmd = "virtio-scsi-pci,id=$id,$addr";

	    if ($iothread) {
		my $iothread_id = "iothread-$id";
		$self->add_object('iothread', $iothread_id);
		$cmd .= ",iothread=$iothread_id";
	    }


	    $buses->{$id} = { command => $cmd };
	}

	return "bus=$id.0,channel=0,scsi-id=0,lun=$index";
    }

    my $maxdev = $type =~ /^lsi/ ? 7 : 256;

    my $controller = int($index / $maxdev);
    my $slot = $index % $maxdev;

    my $id = "scsihw$controller";
    if (!exists($buses->{$id})) {
	my $addr = $self->get_address($id);
	$buses->{$id} = { command => "$type,id=$id,$addr" };
    }
    return "bus=$id.0,channel=0,scsi-id=$slot";
}

sub get_sata_address {
    my ($self, $index) = @_;

    my $controller = int($index / $PVE::QemuServer::MAX_SATA_DISKS);
    my $busname = "ahci$controller";

    my $slot = $index % $PVE::QemuServer::MAX_SATA_DISKS;

    my $buses = $self->{buses};
    if (!exists($buses->{$busname})) {
	my $addr = $self->get_address($busname);
	$buses->{$busname} = {
	    command => "ahci,id=$busname,multifunction=on,$addr"
	};
    }
    return "$busname.$slot";
}

# This is for the '.pxe' machine types as well as migration from qemu <= 2.4
# since those versions also used these.
sub get_network_rom {
    my ($self, $type) = @_;
    return undef if !$self->{use_network_romfiles};
    if ($type eq 'virtio-net-pci') {
	return 'pxe-virtio.rom';
    } elsif ($type eq 'e1000') {
	return 'pxe-e1000.rom';
    } elsif ($type eq 'ne2k') {
	return 'pxe-ne2k_pci.rom';
    } elsif ($type eq 'pcnet') {
	return 'pxe-pcnet.rom';
    } elsif ($type eq 'rtl8139') {
	return 'pxe-rtl8139.rom';
    }
    return undef;
}

sub network_device {
    my ($self, $type) = @_;
    if ($type eq 'virtio') {
	return 'virtio-net-pci';
    }
    return $type;
}

sub set_bios_type {
    my ($self, $type) = @_;

    $self->no_hotplug('bios type');

    return if $type eq 'seabios';
    die "unknown bios type: $type\n" if $type ne 'ovmf';

    my $ovmfbase;

    # prefer the OVMF_CODE variant
    if (-f $PVE::QemuServer::OVMF_CODE) {
	$ovmfbase = $PVE::QemuServer::OVMF_CODE;
    } elsif (-f $PVE::QemuServer::OVMF_IMG) {
	$ovmfbase = $PVE::QemuServer::OVMF_IMG;
    } else {
	die "no uefi base image found\n";
    }

    $self->add_pflash(0, $ovmfbase, 'raw', 1);
}

sub add_ehci_controller {
    my ($self, $id) = @_;
    die "no such ehci controller available on i440fx: $id\n"
	if $id ne 'ehci';
    return if $self->{has_ehci_controller};
    $self->{has_ehci_controller} = 1;
    $self->add_args('-readconfig', '/usr/share/qemu-server/pve-usb.cfg');
}

sub add_uhci_controller {
    my ($self, $id) = @_;
    die "bad name for uhci controller: $id\n" if $id !~ /^uhci/;
    my $buses = $self->{buses};
    return if exists($buses->{$id});
    my $addr = $self->get_address($id);

    my $command = "piix3-usb-uhci,id=$id,$addr";
    if ($self->check_hotplug('usb')) {
	PVE::QemuServer::qemu_deviceadd($command);
    }

    $buses->{$id} = {
	command => $command,
	slot_property => 'port',
    };
}

sub add_xhci_controller {
    my ($self, $id) = @_;
    die "bad name for xhci controller: $id\n" if $id !~ /^xhci/;
    my $buses = $self->{buses};
    return if exists($buses->{$id});
    my $addr = $self->get_address($id);

    my $command = "nec-usb-xhci,id=$id,$addr";
    if ($self->check_hotplug('usb')) {
	PVE::QemuServer::qemu_deviceadd($command);
    }

    $buses->{$id} = {
	command => $command,
	slot_property => 'port',
    };
}

sub add_host_pci_device {
    my ($self, $id, $host, $function, %options) = @_;
    my $addr = $self->get_address("hostpci$id");
    if ($options{multifunction}) {
	$addr .= ".$function";
	$id .= ".$function";
    }

    my $cmd = "vfio-pci,id=$id,host=$host,$addr";
    foreach my $opt (sort keys %options) {
	$cmd .= ",$opt=$options{$opt}";
    }

    $self->{devices}->{$id} = {
	type => 'vfio-pci',
	id => $id,
	command => $cmd,
	%options
    };
}

sub add_host_pcie_device {
    my ($self, $id, $host, $function, %options) = @_;
    die "no pcie bus available in this VM machine type\n";
}

sub add_tablet {
    my ($self) = @_;
    my $command = "usb-tablet,id=tablet,bus=uhci.0,port=1";
    if ($self->check_hotplug('usb')) {
	PVE::QemuServer::qemu_deviceadd($command);
    }
    $self->{devices}->{tablet} = {
	type => 'usb-tablet',
	id => 'tablet',
	command => $command
    };
}

sub remove_tablet {
    my ($self) = @_;
    if ($self->check_hotplug('usb')) {
	PVE::QemuServer::qemu_devicedel('tablet');
    }
    delete $self->{devices}->{tablet};
}

1;
