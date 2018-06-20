package PVE::QemuServer::ConfigMachine;

# This package contains the functionality to translate a PVE VM config into a
# Qemu Machine. (Alternatives we migh add in the future are ways to create a
# machine from a running qemu process to eg. support live-migration of machines
# after "default" changes.)

use strict;
use warnings;

use URI::Escape;

use PVE::Tools;
use PVE::Storage;
use PVE::QemuServer;
use PVE::QemuServer::Memory;

# Changes to the previous config_to_command:
# * x-vga does not override the display device to 'none' anymore, this
#   setting now has to be explicit.

sub create_machine {
    my ($vmid, $conf, $defaults, $forcemachine, $hotplug) = @_;

    my $machine_type = $forcemachine // $conf->{machine} // $defaults->{machine};

    return PVE::QemuServer::Machine->create($vmid, $machine_type,
					    $conf->{name},
					    $hotplug);
}

sub config_to_machine {
    my ($storecfg, $vmid, $conf, $defaults, $forcemachine) = @_;

    my $ostype = $conf->{ostype} // $defaults->{ostype};
    my $vga = $conf->{vga} // $defaults->{vga};

    my $hotplug = PVE::QemuServer::parse_hotplug_features($conf->{hotplug} // '1');

    my $m = create_machine($vmid, $conf, $defaults, $forcemachine, $hotplug);

    my $qemuver = PVE::QemuServer::qemu_version_string($m->qemu_cmd);

    my $machine_type = $m->{machine_type};
    if (!PVE::QemuServer::qemu_machine_feature_enabled($machine_type, $qemuver, 2, 7)) {
	delete $m->{hotplug}->{cpu};
    }

    # Qemu < 2.4 loaded old pxe rom files, so we enforce a pxe machine type.
    if (!PVE::QemuServer::qemu_machine_feature_enabled($machine_type, $qemuver, 2, 4)) {
	$m->{pxe} = 1;
    }

    my $info = {
	ostype => $ostype // '',
	qemu_version => $qemuver,
	qxl_displays => PVE::QemuServer::vga_conf_has_spice($vga),
	win_version => PVE::QemuServer::windows_version($ostype),
    };

    $m->{info} = $info;

    my $smbios = $conf->{smbios1} // $defaults->{smbios1};
    $m->add_smbios('1', $smbios);

    setup_time($m, $conf, $defaults);
    setup_bios($m, $storecfg, $conf, $defaults);
    setup_cpu($m, $conf, $defaults);
    setup_hostpci_devices($m, $conf);
    setup_display_devices($m, $conf, $defaults);
    setup_input_devices($m, $conf, $defaults);
    setup_serial_devices($m, $conf);
    setup_memory($m, $conf);
    setup_usb_devices($m, $conf);

    $m->add_agent() if $conf->{agent};

    my $bootorder = $conf->{boot} || $defaults->{boot};
    my $bootindex_hash = {};
    my $i = 1;
    $bootindex_hash->{$_} = 100 * $i++ foreach split(//, $bootorder);

    setup_disks($m, $storecfg, $conf, $defaults, $bootindex_hash);
    setup_network($m, $conf, $defaults, $bootindex_hash);

    if (my $initiator = PVE::QemuServer::get_initiator_name()) {
	$m->set_iscsi_opts('initiator-name' => $initiator);
    }

    $m->add_args('-S') if $conf->{freeze};
    $m->add_args('-no-acpi') if defined($conf->{acpi}) && $conf->{acpi} == 0;
    $m->add_args('-no-reboot') if  defined($conf->{reboot}) && $conf->{reboot} == 0;

    # Set keyboard layout - for people who really do want to do this in
    # completely wrong places.
    my $kb = $conf->{keyboard} || $defaults->{keyboard};
    $m->add_args('-k', $kb) if defined($kb);

    if (defined(my $args = $conf->{args})) {
	my $arglist = PVE::Tools::split_args($args);
	$m->add_args(@$arglist);
    }

    my $cmd = $m->to_command();

    return ($m, $m->{volume_list}, $m->{spice_port}, $cmd);
}

sub setup_time($$$) {
    my ($m, $conf, $defaults) = @_;

    my $tdf = defined($conf->{tdf}) ? $conf->{tdf} : $defaults->{tdf};
    my $use_localtime = $conf->{localtime};

    my $win_version = $m->{info}->{win_version};
    if ($win_version >= 5) {
	$use_localtime = 1 if !defined($use_localtime);

	# use time drift fix when acpi is enabled
	if (!(defined($conf->{acpi}) && $conf->{acpi} == 0)) {
	    $tdf = 1 if !defined($conf->{tdf});
	}
    }
    if ($win_version >= 6) {
	$m->set_global('kvm-pit.lost_tick_policy' => 'discard');
	$m->add_args('-no-hpet');
    }

    $m->set_rtc_opts(driftfix => 'slew') if $tdf;

    if (my $startdate = $conf->{startdate}) {
	$m->set_rtc_opts(base => $startdate);
    } elsif ($use_localtime) {
	$m->set_rtc_opts(base => 'localtime');
    }
}

sub setup_bios($$$$) {
    my ($m, $storecfg, $conf, $defaults) = @_;

    my $bios = $conf->{bios} // $defaults->{bios};
    $m->set_bios_type($bios);

    if (defined(my $efidisk = $conf->{efidisk0})) {
	my $d = parse_efidisk($conf->{efidisk0});
	my ($path, $format);
	my ($storeid, $volname) = PVE::Storage::parse_volume_id($d->{file}, 1);
	if ($storeid) {
	    $path = PVE::Storage::path($storecfg, $d->{file});
	    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
	    $format = qemu_img_format($scfg, $volname);
	} else {
	    $path = $d->{file};
	    $format = "raw";
	}
	$m->add_pflash(1, $path, $format, 0, 'drive-efidisk0');
    }
}

sub setup_cpu($$$) {
    my ($m, $conf, $defaults) = @_;

    my $sockets = $conf->{smp} || $conf->{sockets} || 1;
    my $cores = $conf->{cores} || 1;
    my $maxcpus = $sockets * $cores;
    my $vcpus = $conf->{vcpus} || $maxcpus;
    my $max_vcpus = $PVE::QemuServer::cpuinfo->{cpus};
    die "This node only supports up to $max_vcpus vcpus per VM\n"
	if $max_vcpus < $maxcpus;

    my $machine_type = $m->{machine_type};
    my $qemuver = $m->{info}->{qemu_version};

    my $nokvm = (defined($conf->{kvm}) && $conf->{kvm} == 0);
    if ($nokvm) {
	$m->disable_kvm();
    }

    my $cpu = $nokvm ? "qemu64" : "kvm64";
    if (my $cputype = $conf->{cpu}) {
	my $cpuconf = PVE::QemuServer::parse_cputype($cputype);
	$cpu = $cpuconf->{cputype};
	$m->set_cpu_opts(kvm => 'off') if $cpuconf->{hidden};
    }
    $m->set_cpu_type($cpu);
    $m->set_smp($vcpus, $sockets, $cores);

    $m->set_cpu_opts('+lahf_lm' => '') if $cpu eq 'kvm64';
    $m->set_cpu_opts('-x2apic' => '')  if $m->{info}->{ostype} eq 'solaris';
    $m->set_cpu_opts('+sep' => '')     if $cpu eq 'kvm64' || $cpu eq 'kvm32';
    $m->set_cpu_opts('-rdtscp' => '')  if $cpu =~ m/^Opteron/;

    if (!$nokvm && PVE::QemuServer::qemu_machine_feature_enabled ($machine_type, $qemuver, 2, 3)) {
	$m->set_cpu_opts('+kvm_pv_unhalt' => '');
	$m->set_cpu_opts('+kvm_pv_eoi' => '');
    }

    $m->set_cpu_opts(enforce => '') if $cpu ne 'host' && !$nokvm;

    my $cpu_vendor = $PVE::QemuServer::cpu_vendor_list->{$cpu} ||
	die "internal error: No vendor for cpu type '$cpu' found"; # should not happen

    $m->set_cpu_opts(vendor => $cpu_vendor) if $cpu_vendor ne 'default';

    setup_hyperv_options($m, $conf, $defaults, $machine_type, $qemuver, $nokvm);

    if (my $watchdog = $conf->{watchdog}) {
	my $wdopts = PVE::QemuServer::parse_watchdog($watchdog);
	$m->add_watchdog($wdopts->{model});

	my $action = $wdopts->{action};
	$m->add_args('-watchdog-action', $action) if $action;
    }
}

sub setup_hyperv_options($$$$$$) {
    my ($m, $conf, $defaults, $machine_type, $qemuver, $nokvm) = @_;

    my $win_version = $m->{info}->{win_version};
    my $gpu_passthrough = $m->{info}->{gpu_passthrough};
    my $bios = $conf->{bios} // $defaults->{bios};

    return if $nokvm;
    return if $win_version < 6;
    return if $bios && $bios eq 'ovmf' && $win_version < 8;

    # Tell the nvidia driver not to be an ass.
    $m->set_cpu_opts(hv_vendor_id => 'proxmox') if $gpu_passthrough;

    if (PVE::QemuServer::qemu_machine_feature_enabled($machine_type, $qemuver, 2, 3)) {
	$m->set_cpu_opts(hv_spinlocks => '0x1fff');
	$m->set_cpu_opts(hv_vapic => '');
	$m->set_cpu_opts(hv_time => '');
    } else {
	$m->set_cpu_opts(hv_spinlocks => '0xffff');
    }

    if (PVE::QemuServer::qemu_machine_feature_enabled($machine_type, $qemuver, 2, 6)) {
	$m->set_cpu_opts(hv_reset => '');
	$m->set_cpu_opts(hv_vpindex => '');
	$m->set_cpu_opts(hv_runtime => '');
    }

    if ($win_version >= 7) {
	$m->set_cpu_opts(hv_relaxed => '');
    }
}

sub setup_hostpci_devices($$) {
    my ($m, $conf) = @_;

    for (my $i = 0; $i < $PVE::QemuServer::MAX_HOSTPCI_DEVICES; $i++)  {
	my $name = "hostpci$i";
	my $devstring = $conf->{$name};
	next if !$devstring;
	my $d = parse_hostpci($devstring);
	next if !$d;

	my %options;

	if (defined($d->{rombar}) && !$d->{rombar}) {
	    $options{rombar} = 0;
	}
	if (defined(my $romfile = $d->{romfile})) {
	    $options{romfile} = "/usr/share/kvm/$romfile";
	}

	if ($d->{'x-vga'}) {
	    $m->{info}->{gpu_passthrough} = 1;
	    $m->set_cpu_opts(kvm => 'off');
	    if (!$conf->{bios} || $conf->{bios} ne 'ovmf') {
		$options{'x-vga'} = 'on';
	    }
	}

	my $add = $d->{pcie} ? sub { return $m->add_pcie_device(@_) }
	                     : sub { return $m->add_pci_device(@_) };


	my $pcidevices = $d->{pciid};
	$options{multifunction} = "on" if @$pcidevices > 1;

	my $funcid=0;
        foreach my $pcidevice (@$pcidevices) {
	    $add->($i, "$pcidevice->{id}.$pcidevice->{function}", $funcid++, %options);
	}
    }
}

sub foreach_dimm {
    my ($m, $hugepages, $memory, $sockets, $func) = @_;
    my $current_size = 1024;
    my $dimm_size = 512;
    if ($hugepages && $hugepages == 1024) {
	$current_size *= $sockets;
	$dimm_size = 1024;
    }
    return if $current_size == $memory;

    my @numa_map = sort { $a <=> $b } keys %{$m->{numa}};

    my $dimm_id = 0;
    for (my $j = 0; $j < 8; $j++) {
	for (my $i = 0; $i < 32; $i++) {
	    my $node = $numa_map[$i % @numa_map];
	    $current_size += $dimm_size;
	    $func->($dimm_id, $node, $dimm_size, $current_size);
	    ++$dimm_id;
	    return $current_size if $current_size >= $memory;
	}
	$dimm_size *= 2;
    }
}

sub setup_memory($$$) {
    my ($m, $conf, $defaults) = @_;

    my $MAX_MEM    = $PVE::QemuServer::Memory::MAX_MEM;
    my $STATIC_MEM = $PVE::QemuServer::Memory::STATICMEM;
    my $MAX_NUMA   = $PVE::QemuServer::Memory::MAX_NUMA;

    $m->add_balloon() if !defined($conf->{balloon}) || $conf->{balloon};

    my $numa = $conf->{numa};
    my $hugepages = $conf->{hugepages};
    my $hotplug = $m->{hotplug};
    my $memory = $conf->{memory} || $defaults->{memory};

    # Hugepages require NUMA, so set NUMA first.
    $m->set_option('numa', $numa);
    $m->set_option('hugepages', $hugepages);

    my $static_memory;

    my $sockets = $conf->{sockets} || 1;
    my $cores = $conf->{cores} || 1;

    if ($hotplug->{memory}) {
	die "NUMA needs to be enabled for memory hotplug\n" if !$numa;
	die "Total memory is bigger than ${MAX_MEM}MB\n" if $memory > $MAX_MEM;

	$static_memory = $STATIC_MEM;
	# If we use "huge" hugepages we need to make sure we allocate enough so
	# that each socket gets a page:
	$static_memory *= $sockets if ($hugepages && $hugepages == 1024);
	# Also means the VM cannot have less total memory than that:
	die "minimum memory must be ${static_memory}MB\n"
	    if ($memory < $static_memory);

	$m->set_memory_opts(maxmem => "${MAX_MEM}M", slots => 255);
    } else {
	$static_memory = $memory;
    }

    $m->set_memory($static_memory);

    my $custom_numa_nodes;
    for (my $i = 0; $i < $MAX_NUMA; $i++) {
	my $confstr = $conf->{"numa$i"};
	next if !$confstr;
	my $node = PVE::QemuServer::parse_numa($confstr);
	next if !$node;

	$custom_numa_nodes = 1;

	if (!$numa) {
	    warn "unused option 'numa$i': numa not enabled\n";
	    last;
	}

	my %options;

	my $hostnodes = '';
	if (defined(my $hostnode_rangelist = $numa->{hostnodes})) {
	    $hostnodes =
		join('\,',
		    map {
			my ($beg, $end) = @$_;

			foreach my $i ($beg .. ($end//$beg)) {
			    die "Requested host NUMA node $i doesn't exist\n"
				if !-d "/sys/devices/system/node/node$i/";
			}

			defined($end) ? "$beg-$end" : $beg
		    }
		    @$hostnode_rangelist);
	}

	if (length($hostnodes)) {
	    $options{'host-nodes'} = $hostnodes;
	    $options{policy} = $node->{policy}
		or die "NUMA memory policy must be defined to assign host nodes\n";
	} elsif ($hugepages) {
	    die "NUMA nodes need to be assigned to host nodes in order to use hugepages\n";
	}

	$m->add_numa_node($i, $node->{cpus}, $node->{memory}, %options);
    }

    if (!$custom_numa_nodes && $numa) {
	my $numa_mem = $static_memory / $sockets;
	die "cannot split ${static_memory}M evenly across $sockets sockets\n"
	    if $numa_mem != int($numa_mem);
	for (my $i = 0; $i < $sockets; $i++)  {
	    if (!-d "/sys/devices/system/node/node$i/" && $hugepages) {
		die "Not enough host numa nodes for automatic assignment."
		   ." Please configure virtual numa nodes.\n";
	    }

	    my $beg = $cores * $i;
	    my $end = $beg + $cores - 1 if $cores > 1;
	    $m->add_numa_node($i, [[$beg, $end]], $numa_mem);
	}
    }

    if ($hotplug->{memory}) {
        foreach_dimm($m, $hugepages, $memory, $sockets, sub {
            my ($dimm_id, $numa_node_id, $dimm_size, $current_size) = @_;

            $m->add_dimm($dimm_id, $numa_node_id, $dimm_size);

            #if dimm_memory is not aligned to dimm map
            if ($current_size > $memory) {
                 $conf->{memory} = $current_size;
                 PVE::QemuConfig->write_config($m->{vmid}, $conf);
            }
        });
    }

    $m->check_memory();
}

# These are all the options we directly copy from our config into the drive
# option list.
my @qemu_drive_options = qw(
    heads secs cyls trans
    media format cache
    snapshot
    rerror werror
    aio
    discard
    iops iops_rd iops_wr iops_max iops_rd_max iops_wr_max);
# 'serial' is transformed via URI::Escape::uri_unescape
# rate limits need unit conversion

sub add_drive($$$) {
    my ($m, $storecfg, $drive) = @_;

    my $vmid = $m->{vmid};

    my $path;
    my $format;
    my $volid = $drive->{file};
    my $is_volume;

    my $is_cdrom = PVE::QemuServer::drive_is_cdrom($drive);

    if ($is_cdrom) {
	$path = PVE::QemuServer::get_iso_path($storecfg, $vmid, $volid);
    } else {
	my ($storeid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
	if ($storeid) {
	    $path = PVE::Storage::path($storecfg, $volid);
	    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
	    $format = PVE::QemuServer::qemu_img_format($scfg, $volname);
	    $is_volume = 1;
	} else {
	    $path = $volid;
	    $format = "raw";
	}
    }

    my %opts = map { $_ => $drive->{$_} } @qemu_drive_options;

    # Default values for non-explicilty specified options:
    $opts{cache} ||= 'none' if !$is_cdrom;
    $opts{format} ||= $format if $format; # only if we know it
    if (!$opts{aio}) {
	# We want to use aio=native by default, but it only works with O_DIRECT
	my $o_direct = ($opts{cache} =~ /^(?:off|none|directsync)$/) if !$is_cdrom;
	$opts{aio} = $o_direct ? 'native' : 'threads';
    }

    # Escape serial number
    if (my $serial = $drive->{serial}) {
	$opts{serial} = URI::Escape::uri_unescape($serial);
    }

    # Convert rate limits to bytes
    foreach my $o (qw(mbps mbps_rd mbps_wr)) {
	if (my $v = $drive->{$o}) {
	    $opts{$o} = int($v * 1024 * 1024);
	}
    }

    if (!$is_cdrom) {
	if (defined($drive->{detect_zeroes}) && !$drive->{detect_zeroes}) {
	    $opts{'detect-zeroes'} = 'off';
	} elsif ($drive->{discard}) {
	    $opts{'detect-zeroes'} = $opts{discard} eq 'on' ? 'unmap' : 'on';
	} else {
	    # This used to be our default with discard not being specified:
	    $opts{'detect-zeroes'} = 'on';
	}
    }

    my $interface = $drive->{interface};
    my $index = $drive->{index};
    my $id = "drive-${interface}$index";
    $m->add_drive($path, $id, %opts);
    push @{$m->{volume_list}}, $volid if $is_volume;
    return $id;
}

sub add_disk($$$$$$) {
    my ($m, $conf, $defaults, $id, $drive, $drive_id) = @_;

    my $interface = $drive->{interface};
    my $index = $drive->{index};

    my %options;
    # Some options can be copied as they are.
    foreach my $o (qw(iothread bootindex)) {
	if (my $v = $drive->{$o}) {
	    $options{$o} = $v;
	}
    }
    if ($interface eq 'scsi') {
	$options{scsihw} = $conf->{scsihw} // $defaults->{scsihw};
    }

    $m->add_disk($interface, $index, $drive_id, %options);
}

sub setup_disks($$$$$) {
    my ($m, $storecfg, $conf, $defaults, $bootindex_hash) = @_;
    PVE::QemuServer::foreach_drive($conf, sub {
	my ($id, $drive) = @_;

	if (PVE::QemuServer::drive_is_cdrom($drive)) {
	    if ($bootindex_hash->{d}) {
		$drive->{bootindex} = $bootindex_hash->{d}++;
	    }
	} else {
	    if ($bootindex_hash->{c}) {
		$drive->{bootindex} = $bootindex_hash->{c}
		    if $conf->{bootdisk} && ($conf->{bootdisk} eq $id);
		$bootindex_hash->{c}++;
	    }
	}

	my $drive_id = add_drive($m, $storecfg, $drive);
	add_disk($m, $conf, $defaults, $id, $drive, $drive_id);
    });
}

sub setup_network($$$$) {
    my ($m, $conf, $defaults, $bootindex_hash) = @_;

    my $vmid = $m->{vmid};

    for (my $i = 0; $i < $PVE::QemuServer::MAX_NETS; $i++) {
	my $netid = "net$i";
	my $desc = $conf->{$netid};
	next if !$desc;
	my $net = PVE::QemuServer::parse_net($desc);
	next if !$net;

	if ($bootindex_hash->{n}) {
	    $net->{bootindex} = $bootindex_hash->{n}++;
	}

	my $ifname = "tap${vmid}i$i";
	my $hostname = $conf->{name} || "vm$vmid";

	my %options;

	my $queues = $net->{queues};
	$options{queues} = $queues;

	if (my $bootindex = $net->{bootindex}) {
	    $options{bootindex} = $bootindex;
	}

	$m->add_tap_device($net->{model}, $netid, $ifname,
			   $net->{bridge}, $hostname, $queues);
	$m->add_network_device($net->{model}, $netid, $net->{macaddr}, $netid,
			       %options);
    }
}

sub setup_display_devices($$$) {
    my ($m, $conf, $defaults) = @_;

    my $vga = $conf->{vga} // $defaults->{vga};

    $m->add_vga($vga);
    my $qxl_displays = $m->{info}->{qxl_displays};
    if ($qxl_displays) {
	if ($qxl_displays > 1) {
	    if ($m->{info}->{win_version}) {
		for (2..$qxl_displays) {
		    $m->add_vga('qxl', ram_size => 67108864, vram_size => 33554432);
		}
	    } else {
		$m->set_global('qxl-vga.ram_size' => 134217728);
		$m->set_global('qxl-vga.vram_size' => 67108864);
	    }
	}

	$m->add_spice();
    }
}

sub setup_input_devices($$$) {
    my ($m, $conf, $defaults) = @_;

    my $tablet = $conf->{tablet};
    if (!defined($tablet)) {
	my $vga = $conf->{vga} || '';
	if ($m->{info}->{qxl_displays} || $vga =~ /^serial\d+$/) {
	    $tablet = 0;
	} else {
	    $tablet = $defaults->{tablet};
	}
    }
    $m->add_tablet() if $tablet;
}

sub setup_serial_devices($$) {
    my ($m, $conf) = @_;

    for (my $i = 0; $i < $PVE::QemuServer::MAX_SERIAL_PORTS; $i++)  {
	if (my $path = $conf->{"serial$i"}) {
	    if ($path eq 'socket') {
		my $socket = "/var/run/qemu-server/$m->{vmid}.serial$i";
		$m->add_serial_socket("serial$i", $socket);
	    } else {
		die "no such serial device\n" if ! -c $path;
		$m->add_serial_device("serial$i", $path);
	    }
	}
    }
}

sub setup_parallel_devices($$) {
    my ($m, $conf) = @_;

    for (my $i = 0; $i < $PVE::QemuServer::MAX_PARALLEL_PORTS; $i++)  {
	if (my $path = $conf->{"parallel$i"}) {
	    die "no such parallel device\n" if ! -c $path;
	    my $id = "parallel$i";

	    if ($path =~ m!^/dev/usb/lp!) {
		$m->add_parallel_tty($id, $path);
	    } else {
		$m->add_parallel_parport($id, $path);
	    }
	}
    }
}

sub setup_usb_devices($$) {
    my ($m, $conf) = @_;

    my $max_usb_devices = $PVE::QemuServer::MAX_USB_DEVICES;
    for (my $i = 0; $i < $max_usb_devices; $i++) {
	my $entry = $conf->{"usb$i"} or next;
	my $data = PVE::QemuServer::parse_usb($entry);
	next if !$data;
	my $host = $data->{host};
	next if !defined($host);
	use PVE::QemuServer::USB 'parse_usb_device';
	my $device = parse_usb_device($host);

	my $id = "usb$i";

	my $vendorid = $device->{vendorid};
	my $productid = $device->{productid};
	my $hostbus = $device->{hostbus};
	my $hostport = $device->{hostport};
	my $usb_bus = $data->{usb3} ? 'xhci' : 'ehci';
	if ($device->{spice}) {
	    # usb redir support for spice, currently no usb3
	    $m->add_usb_spice_redirection($i);
	} elsif (defined($vendorid) && defined($productid)) {
	    $m->add_usb_device($id, $usb_bus, $vendorid, $productid);
	} elsif (defined($hostbus) && defined($hostport)) {
	    $m->add_usb_host_port($id, $usb_bus, $hostbus, $hostport);
	} else {
	    warn "bad usb device: usb$i: $entry\n";
	}
    }
}

1;
