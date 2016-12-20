package PVE::QemuServer::Memory;

use strict;
use warnings;
use PVE::QemuServer;
use PVE::Tools qw(run_command lock_file lock_file_full file_read_firstline dir_glob_foreach);
use PVE::Exception qw(raise raise_param_exc);

my $MAX_NUMA = 8;
my $MAX_MEM = 4194304;
my $STATICMEM = 1024;

sub get_numa_node_list {
    my ($conf) = @_;
    my @numa_map;
    for (my $i = 0; $i < $MAX_NUMA; $i++) {
	my $entry = $conf->{"numa$i"} or next;
	my $numa = PVE::QemuServer::parse_numa($entry) or next;
	push @numa_map, $i;
    }
    return @numa_map if @numa_map;
    my $sockets = $conf->{sockets} || 1;
    return (0..($sockets-1));
}

# only valid when numa nodes map to a single host node
sub get_numa_guest_to_host_map {
    my ($conf) = @_;
    my $map = {};
    for (my $i = 0; $i < $MAX_NUMA; $i++) {
	my $entry = $conf->{"numa$i"} or next;
	my $numa = PVE::QemuServer::parse_numa($entry) or next;
	$map->{$i} = print_numa_hostnodes($numa->{hostnodes});
    }
    return $map if %$map;
    my $sockets = $conf->{sockets} || 1;
    return {map { $_ => $_ } (0..($sockets-1))};
}

sub foreach_dimm {
    my ($conf, $vmid, $memory, $sockets, $func) = @_;

    my $dimm_id = 0;
    my $current_size = 0;
    my $dimm_size = 0;

    if($conf->{hugepages} && $conf->{hugepages} eq '1024') {
	$current_size = $STATICMEM * $sockets;
	$dimm_size = 1024;
    } else {
	$current_size = $STATICMEM;
	$dimm_size = 512;
    }

    return if $current_size == $memory;

    my @numa_map = get_numa_node_list($conf);

    for (my $j = 0; $j < 8; $j++) {
	for (my $i = 0; $i < 32; $i++) {
	    my $name = "dimm${dimm_id}";
	    $dimm_id++;
	    my $numanode = $numa_map[$i % @numa_map];
	    $current_size += $dimm_size;
	    &$func($conf, $vmid, $name, $dimm_size, $numanode, $current_size, $memory);
	    return  $current_size if $current_size >= $memory;
	}
	$dimm_size *= 2;
    }
}

sub foreach_reverse_dimm {
    my ($conf, $vmid, $memory, $sockets, $func) = @_;

    my $dimm_id = 253;
    my $current_size = 0;
    my $dimm_size = 0;

    if($conf->{hugepages} && $conf->{hugepages} eq '1024') {
	$current_size = 8355840;
	$dimm_size = 131072;
    } else {
	$current_size = 4177920;
	$dimm_size = 65536;
    }

    return if $current_size == $memory;

    my @numa_map = get_numa_node_list($conf);

    for (my $j = 0; $j < 8; $j++) {
	for (my $i = 0; $i < 32; $i++) {
 	    my $name = "dimm${dimm_id}";
 	    $dimm_id--;
	    my $numanode = $numa_map[(31-$i) % @numa_map];
 	    $current_size -= $dimm_size;
 	    &$func($conf, $vmid, $name, $dimm_size, $numanode, $current_size, $memory);
	    return  $current_size if $current_size <= $memory;
	}
	$dimm_size /= 2;
    }
}

sub qemu_add_dimm {
    my ($vmid, $conf, $numa_hostmap, $numanode, $dimm_size, $name) = @_;

    use integer;

    if ($conf->{hugepages}) {
	my $hugepages_size = hugepages_size($conf, $dimm_size);
	my $path = hugepages_mount_path($hugepages_size);
	my $host_numanode = $numa_hostmap->{$numanode};
	my $hugepages_topology->{$hugepages_size}->{$host_numanode} = hugepages_nr($dimm_size, $hugepages_size);

	my $code = sub {
	    my $hugepages_host_topology = hugepages_host_topology();
	    hugepages_allocate($hugepages_topology, $hugepages_host_topology);

	    eval {
		PVE::QemuServer::vm_mon_cmd($vmid, "object-add",
		    'qom-type' => "memory-backend-file",
		    id => "mem-$name",
		    props => {
			size => $dimm_size*(1024*1024),
			'mem-path' => $path,
			share => JSON::true,
			prealloc => JSON::true
		    }
		);
	    };
	    if (my $err = $@) {
		hugepages_reset($hugepages_host_topology);
		die $err;
	    }

	    hugepages_pre_deallocate($hugepages_topology);
	};
	hugepages_update_locked($code);
    } else {
	PVE::QemuServer::vm_mon_cmd($vmid, "object-add",
	    'qom-type' => "memory-backend-ram",
	    id => "mem-$name",
	    props => {
		size => $dimm_size*(1024*1024)
	    }
	);
    }
}

sub qemu_memory_hotplug {
    my ($vmid, $conf, $defaults, $opt, $value) = @_;

    return $value if !PVE::QemuServer::check_running($vmid);

    die "static memory cannot be hot-plugged if dimm-hotplugging is used\n"
	if defined($conf->{dimms});

    my $sockets = 1;
    $sockets = $conf->{sockets} if $conf->{sockets};

    my $memory = $conf->{memory} || $defaults->{memory};
    $value = $defaults->{memory} if !$value;
    return $value if $value == $memory;

    my $static_memory = $STATICMEM;
    $static_memory *= $sockets if ($conf->{hugepages} && $conf->{hugepages} eq '1024');

    die "memory can't be lower than $static_memory MB" if $value < $static_memory;
    die "you cannot add more memory than $MAX_MEM MB!\n" if $memory > $MAX_MEM;

    if($value > $memory) {

	my $numa_hostmap = get_numa_guest_to_host_map($conf) if $conf->{hugepages};

    	foreach_dimm($conf, $vmid, $value, $sockets, sub {
	    my ($conf, $vmid, $name, $dimm_size, $numanode, $current_size, $memory) = @_;

		return if $current_size <= $conf->{memory};

		eval {
		    qemu_add_dimm($vmid, $conf, $numa_hostmap, $numanode, $dimm_size, $name);
		};
		if (my $err = $@) {
		    eval { PVE::QemuServer::qemu_objectdel($vmid, "mem-$name"); };
		    die $err;
		}

		eval { PVE::QemuServer::vm_mon_cmd($vmid, "device_add", driver => "pc-dimm", id => "$name", memdev => "mem-$name", node => $numanode) };
		if (my $err = $@) {
		    eval { PVE::QemuServer::qemu_objectdel($vmid, "mem-$name"); };
		    die $err;
		}
		#update conf after each succesful module hotplug
		$conf->{memory} = $current_size;
		PVE::QemuConfig->write_config($vmid, $conf);
	});

    } else {

    	foreach_reverse_dimm($conf, $vmid, $value, $sockets, sub {
	    my ($conf, $vmid, $name, $dimm_size, $numanode, $current_size, $memory) = @_;

		return if $current_size >= $conf->{memory};
		print "try to unplug memory dimm $name\n";

		my $retry = 0;
	        while (1) {
		    eval { PVE::QemuServer::qemu_devicedel($vmid, $name) };
		    sleep 3;
		    my $dimm_list = qemu_dimm_list($vmid);
		    last if !$dimm_list->{$name};
		    raise_param_exc({ $name => "error unplug memory module" }) if $retry > 5;
		    $retry++;
		}

		#update conf after each succesful module unplug
		$conf->{memory} = $current_size;

		eval { PVE::QemuServer::qemu_objectdel($vmid, "mem-$name"); };
		PVE::QemuConfig->write_config($vmid, $conf);
	});
    }
}

sub parse_dimmlist {
    my ($list) = @_;
    return if $list eq 'none';
    return map {
	/^(\d+)@(\d+)(?:x(\d+))?$/
	? ([$1, $2]) x ($3//1)
	: die "bad dimm element: $_\n"
    } PVE::Tools::split_list($list);
}

my $qemu_update_dimm_config  = sub {
    my ($vmid, $conf, $cur_sizes_by_node, $write) = @_;
    my $value = '';
    foreach my $node (sort {$a <=> $b} keys %$cur_sizes_by_node) {
	my $cur_sizes = $cur_sizes_by_node->{$node};
	foreach my $dimm_size (sort {$a <=> $b} keys %$cur_sizes) {
	    my $sizes = $cur_sizes->{$dimm_size};
	    my $count = scalar(@$sizes);
	    next if !$count;
	    $value .= ';' if length($value);
	    $value .= "${dimm_size}\@${node}";
	    $value .= "x$count" if $count != 1;
	}
    }
    $value = 'none' if !length($value);
    if ($write) {
	$conf->{dimms} = $value;
	PVE::QemuConfig->write_config($vmid, $conf);
    }
    return $value;
};

sub current_dimm_config {
    my ($vmid, $conf, $defaults, $running, $cur_sizes_by_node) = @_;

    my $old = $conf->{dimms};

    if ($running) {
	# use the above $cur_sizes_by_node info which was queried from qemu.
	if (!$old) {
	    use integer;
	    # We used the old hotplug method before, so we first caclulcate the
	    # amount of RAM the machine is currently using:
	    my $memdevs = PVE::QemuServer::vm_mon_cmd_nocheck($vmid, "query-memdev");
	    my $memory = 0;
	    $memory += $_->{size} foreach @$memdevs;
	    $memory /= 1024*1024;

	    # Then subtract the dimm configuration
	    foreach my $node (keys %$cur_sizes_by_node) {
		my $sizes = $cur_sizes_by_node->{$node};
		foreach my $size (keys %$sizes) {
		    my $size_ids = $sizes->{$size};
		    $memory -= $size * scalar(@$size_ids);
		}
	    }
	    # Then we have our static memory:
	    $conf->{memory} = $memory;
	    PVE::QemuConfig->write_config($vmid, $conf);
	}
    } elsif ($old && $old ne 'current') {
	# Not running and we have a dimm config, no change.
	return $old;
    } else {
	# Not running and old config model was used. Convert:
	$cur_sizes_by_node = {};
	my $memory = $conf->{memory} || $defaults->{memory};
	my $sockets = $conf->{sockets} || 1;
	foreach_dimm($conf, $vmid, $memory, $sockets, sub {
	    my ($conf, $vmid, $name, $dimm_size, $numanode, $current_size, $memory) = @_;
	    push @{$cur_sizes_by_node->{$numanode}->{$dimm_size}}, $name;
	});
    }

    return &$qemu_update_dimm_config($vmid, $conf, $cur_sizes_by_node, 0)
}

sub qemu_dimm_hotplug {
    my ($vmid, $conf, $defaults, $opt, $value) = @_;

    my $running = PVE::QemuServer::check_running($vmid);

    if ($running && !defined($value)) {
	die "dimms need to be unplugged before deleting the dimm property\n"
	    if $conf->{dimms} && $conf->{dimms} ne 'none';
	return undef;
    }

    my %allnodes;
    my %allids;
    my %allsizes;
    my $qemudimms;
    my $cur_sizes_by_node = {};
    if ($running) {
	$qemudimms = qemu_dimm_list($vmid);
	foreach my $id (keys %$qemudimms) {
	    my $dimm = $qemudimms->{$id};
	    my $node = $dimm->{node};
	    my $size = $dimm->{size};
	    my $megs = int($size/(1024*1024));
	    next if ($megs*1024*1024) != $size; # sanity check
	    $allids{$id} = 1;
	    $allnodes{$node} = 1;
	    $allsizes{$megs} = 1;
	    push @{$cur_sizes_by_node->{$node}->{$megs}}, $id;
	}
    }

    return current_dimm_config($vmid, $conf, $defaults, $running, $cur_sizes_by_node)
	if $value eq 'current';

    return $value if !$running;

    my @new_dimms = parse_dimmlist($value);
    foreach my $dimm (@new_dimms) {
	my ($dimm_size, $numanode) = @$dimm;
	$allnodes{$numanode} = 1;
	$allsizes{$dimm_size} = 1;
    }

    # check against $MAX_MEM and fill %allnodes
    my $totalmem = 0;
    my $totalslots = 0;
    my $dimm_size_count_per_node = {};
    foreach my $dimm (@new_dimms) {
	my ($dimm_size, $numanode) = @$dimm;
	next if !$dimm_size;
	$allsizes{$dimm_size} = 1;
	$allnodes{$numanode} = 1;
	$totalmem += $dimm_size;
	++$totalslots;
	my $dimm_size_count = ($dimm_size_count_per_node->{$numanode} //= {});
	++($dimm_size_count->{$dimm_size}//=0);
    }
    die "you cannot add more memory than $MAX_MEM MB!\n"
	if $totalmem > $MAX_MEM;
    die "cannot use more than 64 dimm slots ($totalslots requested)\n"
	if $totalslots > 64;

    my $id = 0;
    eval {
	my %size_done;
	my $numa_hostmap = get_numa_guest_to_host_map($conf) if $conf->{hugepages};
	foreach my $numanode (keys %allnodes) {
	    my $sizecounts = ($dimm_size_count_per_node->{$numanode}//{});
	    my $cur_sizes = ($cur_sizes_by_node->{$numanode} //= {});
	    foreach my $dimm_size (sort keys %allsizes) {
		my $count = $sizecounts->{$dimm_size} // 0;
		my $cur_ids = ($cur_sizes->{$dimm_size}//=[]);
		while ($count > scalar(@$cur_ids)) {
		    ++$id while $allids{"dimm$id"};
		    my $name = "dimm$id";
		    eval {
			qemu_add_dimm($vmid, $conf, $numa_hostmap, $numanode, $dimm_size, $name);
			PVE::QemuServer::vm_mon_cmd($vmid, "device_add",
			    driver => "pc-dimm",
			    id => "$name",
			    memdev => "mem-$name",
			    node => $numanode
			);
		    };
		    if (my $err = $@) {
			eval { PVE::QemuServer::qemu_objectdel($vmid, "mem-$name"); };
			die $err;
		    }

		    # update ids for value building below
		    $allids{$name} = 1;
		    push @$cur_ids, $name;
		    &$qemu_update_dimm_config($vmid, $conf, $cur_sizes_by_node, 1);
		}
		my $index = scalar(@$cur_ids);
		while ($count < scalar(@$cur_ids) && $index-- > 0) {
		    my $name = $cur_ids->[$index];
		    my $dimm = $qemudimms->{$name};
		    die "bad dimm name: $dimm\n" if !$dimm; # sanity check
		    if (!$dimm->{hotpluggable}) {
			warn "skipping non-hotpluggable dimm $name\n";
			next;
		    }
		    eval {
			PVE::QemuServer::qemu_devicedel($vmid, "$name");
			sleep 1;
			foreach(1..3) {
			    my $dimm_list = qemu_dimm_list($vmid);
			    last if !$dimm_list->{$name};
			    sleep 3;
			}
			PVE::QemuServer::qemu_objectdel($vmid, "mem-$name");
		    };
		    if (my $err = $@) {
			warn "failed to delete dimm $name, trying another: ($err)\n";
			# Try another...
			next;
		    }

		    $allids{$name} = 0;
		    my ($cur_id) = ($name =~ /^dimm(\d+)$/);
		    $id = $cur_id if $cur_id < $id;
		    # update ids for value building below
		    splice @$cur_ids, $index, 1;
		    &$qemu_update_dimm_config($vmid, $conf, $cur_sizes_by_node, 1);
		}
	    }
	}
    };
    warn $@ if $@;
    return &$qemu_update_dimm_config($vmid, $conf, $cur_sizes_by_node, 0);
}

sub qemu_dimm_list {
    my ($vmid) = @_;

    my $dimmarray = PVE::QemuServer::vm_mon_cmd_nocheck($vmid, "query-memory-devices");
    my $dimms = {};

    foreach my $dimm (@$dimmarray) {
	my $data = $dimm->{data};
	$dimms->{$data->{id}} = $data;
    }
    return $dimms;
}

sub config {
    my ($conf, $vmid, $sockets, $cores, $defaults, $hotplug_features, $cmd, $qemu_dimms) = @_;

    my $dimmlist = $conf->{dimms};
    my @dimms = parse_dimmlist($dimmlist) if $dimmlist;
    
    my $memory = $conf->{memory} || $defaults->{memory};
    my $static_memory = 0;

    if ($hotplug_features->{memory}) {
	die "NUMA needs to be enabled for memory hotplug\n" if !$conf->{numa};
	die "Total memory is bigger than ${MAX_MEM}MB\n" if $memory > $MAX_MEM;

	if ($dimmlist) {
	    $static_memory = $memory;
	} else {
	    $static_memory = $STATICMEM;
	    $static_memory *= $sockets if $conf->{hugepages} && $conf->{hugepages} eq '1024';
	}

	die "minimum memory must be ${static_memory}MB\n" if($memory < $static_memory);
	push @$cmd, '-m', "size=${static_memory},slots=255,maxmem=${MAX_MEM}M";

    } else {
	# without hotplugging dimms are simply added to the memory size...
	$memory += $_->[0] foreach @dimms;
	$static_memory = $memory;
	push @$cmd, '-m', $static_memory;
    }

    die "numa needs to be enabled to use hugepages" if $conf->{hugepages} && !$conf->{numa};

    if ($conf->{numa}) {

	my $numa_totalmemory = undef;
	for (my $i = 0; $i < $MAX_NUMA; $i++) {
	    next if !$conf->{"numa$i"};
	    my $numa = PVE::QemuServer::parse_numa($conf->{"numa$i"});
	    next if !$numa;
	    # memory
	    die "missing NUMA node$i memory value\n" if !$numa->{memory};
	    my $numa_memory = $numa->{memory};
	    $numa_totalmemory += $numa_memory;

	    my $mem_object = print_mem_object($conf, "ram-node$i", $numa_memory);

	    # cpus
	    my $cpulists = $numa->{cpus};
	    die "missing NUMA node$i cpus\n" if !defined($cpulists);
	    my $cpus = join(',cpus=', map {
		my ($start, $end) = @$_;
		defined($end) ? "$start-$end" : $start
	    } @$cpulists);

	    # hostnodes
	    my $hostnodelists = $numa->{hostnodes};
	    if (defined($hostnodelists)) {

		my $hostnodes = print_numa_hostnodes($hostnodelists);

		# policy
		my $policy = $numa->{policy};
		die "you need to define a policy for hostnode $hostnodes\n" if !$policy;
		$mem_object .= ",host-nodes=$hostnodes,policy=$policy";
	    } else {
		die "numa hostnodes need to be defined to use hugepages" if $conf->{hugepages};
	    }

	    push @$cmd, '-object', $mem_object;
	    push @$cmd, '-numa', "node,nodeid=$i,cpus=$cpus,memdev=ram-node$i";
	}

	die "total memory for NUMA nodes must be equal to vm static memory\n"
	    if $numa_totalmemory && $numa_totalmemory != $static_memory;

	#if no custom tology, we split memory and cores across numa nodes
	if(!$numa_totalmemory) {

	    my $numa_memory = ($static_memory / $sockets);

	    for (my $i = 0; $i < $sockets; $i++)  {
		die "host NUMA node$i doesn't exist\n" if ! -d "/sys/devices/system/node/node$i/" && $conf->{hugepages};

		my $cpustart = ($cores * $i);
		my $cpuend = ($cpustart + $cores - 1) if $cores && $cores > 1;
		my $cpus = $cpustart;
		$cpus .= "-$cpuend" if $cpuend;

		my $mem_object = print_mem_object($conf, "ram-node$i", $numa_memory);

		push @$cmd, '-object', $mem_object;
		push @$cmd, '-numa', "node,nodeid=$i,cpus=$cpus,memdev=ram-node$i";
	    }
	}
    }

    if ($hotplug_features->{memory}) {
	if ($qemu_dimms) {
	    foreach my $name (keys %$qemu_dimms) {
		my $dimm = $qemu_dimms->{$name};
		my $size = $dimm->{size};
		my $megs = $size / (1024*1024);
		die "migration requested dimm size of invalid size\n"
		    if $megs*1024*1024 != $size;
		my $mem_object = print_mem_object($conf, "mem-$name", $megs);
		push @$cmd, '-object', $mem_object;
		push @$cmd, '-device', "pc-dimm,id=$name,memdev=mem-$name"
		    . ",slot=$dimm->{slot}"
		    . ",node=$dimm->{node}"
		    . sprintf(",addr=0x%x", $dimm->{addr});
	    }
	} elsif ($dimmlist) {
	    my $id = 0;
	    foreach my $dimm (@dimms) {
		my ($dimm_size, $numanode) = @$dimm;
		my $name = "dimm$id";
		$id++;
		next if !$dimm_size; # size 0 is used for empty slots during migration
		my $mem_object = print_mem_object($conf, "mem-$name", $dimm_size);
		push @$cmd, '-object', $mem_object;
		push @$cmd, '-device', "pc-dimm,id=$name,memdev=mem-$name,node=$numanode";
	    }
	} else {
	    foreach_dimm($conf, $vmid, $memory, $sockets, sub {
		my ($conf, $vmid, $name, $dimm_size, $numanode, $current_size, $memory) = @_;

		my $mem_object = print_mem_object($conf, "mem-$name", $dimm_size);

		push @$cmd, '-object' , $mem_object;
		push @$cmd, '-device', "pc-dimm,id=$name,memdev=mem-$name,node=$numanode";

		#if dimm_memory is not aligned to dimm map
		if($current_size > $memory) {
		     $conf->{memory} = $current_size;
		     PVE::QemuConfig->write_config($vmid, $conf);
		}
	    });
	}
    }
}

sub print_mem_object {
    my ($conf, $id, $size) = @_;

    if ($conf->{hugepages}) {

	my $hugepages_size = hugepages_size($conf, $size);
	my $path = hugepages_mount_path($hugepages_size);

	return "memory-backend-file,id=$id,size=${size}M,mem-path=$path,share=on,prealloc=yes";
    } else {
	return "memory-backend-ram,id=$id,size=${size}M";
    }

}

sub print_numa_hostnodes {
    my ($hostnodelists) = @_;

    my $hostnodes;
    foreach my $hostnoderange (@$hostnodelists) {
	my ($start, $end) = @$hostnoderange;
	$hostnodes .= ',' if $hostnodes;
	$hostnodes .= $start;
	$hostnodes .= "-$end" if defined($end);
	$end //= $start;
	for (my $i = $start; $i <= $end; ++$i ) {
	    die "host NUMA node$i doesn't exist\n" if ! -d "/sys/devices/system/node/node$i/";
	}
    }
    return $hostnodes;
}

sub hugepages_mount {

   my $mountdata = PVE::ProcFSTools::parse_proc_mounts();

   foreach my $size (qw(2048 1048576)) {
	return if (! -d "/sys/kernel/mm/hugepages/hugepages-${size}kB");

	my $path = "/run/hugepages/kvm/${size}kB";

	my $found = grep {
	    $_->[2] =~ /^hugetlbfs/ &&
	    $_->[1] eq $path
	} @$mountdata;

	if (!$found) {

	    File::Path::make_path($path) if (!-d $path);
	    my $cmd = ['/bin/mount', '-t', 'hugetlbfs', '-o', "pagesize=${size}k", 'hugetlbfs', $path];
	    run_command($cmd, errmsg => "hugepage mount error");
	}
   }
}

sub hugepages_mount_path {
   my ($size) = @_;

   $size = $size * 1024;
   return "/run/hugepages/kvm/${size}kB";

}

sub hugepages_nr {
  my ($size, $hugepages_size) = @_;

  return $size / $hugepages_size;
}

sub hugepages_size {
   my ($conf, $size) = @_;

   die "hugepages option is not enabled" if !$conf->{hugepages};

   if ($conf->{hugepages} eq 'any') {

	#try to use 1GB if available && memory size is matching
	if (-d "/sys/kernel/mm/hugepages/hugepages-1048576kB" && ($size % 1024 == 0)) {
	    return 1024;
	} else {
	    return 2;
	}

   } else {

	my $hugepagesize = $conf->{hugepages} * 1024 . "kB";

	if (! -d "/sys/kernel/mm/hugepages/hugepages-$hugepagesize") {
		die "your system doesn't support hugepages of $hugepagesize";
	}
	die "Memory size $size is not a multiple of the requested hugepages size $hugepagesize" if ($size % $conf->{hugepages}) != 0;
	return $conf->{hugepages};
   }

}

sub hugepages_topology {
    my ($conf) = @_;

    my $hugepages_topology = {};

    return if !$conf->{numa};

    my $defaults = PVE::QemuServer::load_defaults();
    my $memory = $conf->{memory} || $defaults->{memory};
    my $static_memory = 0;
    my $sockets = 1;
    $sockets = $conf->{smp} if $conf->{smp}; # old style - no longer iused
    $sockets = $conf->{sockets} if $conf->{sockets};
    my $numa_custom_topology = undef;
    my $hotplug_features = PVE::QemuServer::parse_hotplug_features(defined($conf->{hotplug}) ? $conf->{hotplug} : '1');

    if ($hotplug_features->{memory}) {
	$static_memory = $STATICMEM;
	$static_memory *= $sockets if ($conf->{hugepages} && $conf->{hugepages} eq '1024');
    } else {
	$static_memory = $memory;
    }

    #custom numa topology
    for (my $i = 0; $i < $MAX_NUMA; $i++) {
	next if !$conf->{"numa$i"};
	my $numa = PVE::QemuServer::parse_numa($conf->{"numa$i"});
	next if !$numa;

	$numa_custom_topology = 1;
	my $numa_memory = $numa->{memory};
	my $hostnodelists = $numa->{hostnodes};
	my $hostnodes = print_numa_hostnodes($hostnodelists);

        die "more than 1 hostnode value in numa node is not supported when hugepages are enabled" if $hostnodes !~ m/^(\d)$/;
        my $hugepages_size = hugepages_size($conf, $numa_memory);
        $hugepages_topology->{$hugepages_size}->{$hostnodes} += hugepages_nr($numa_memory, $hugepages_size);

    }

    #if no custom numa tology, we split memory and cores across numa nodes
    if(!$numa_custom_topology) {

	my $numa_memory = ($static_memory / $sockets);

	for (my $i = 0; $i < $sockets; $i++)  {

	    my $hugepages_size = hugepages_size($conf, $numa_memory);
	    $hugepages_topology->{$hugepages_size}->{$i} += hugepages_nr($numa_memory, $hugepages_size);
	}
    }

    if ($hotplug_features->{memory}) {
	my $numa_hostmap = get_numa_guest_to_host_map($conf);

	if (defined(my $dimmlist = $conf->{dimms})) {
	    my @dimms = parse_dimmlist($dimmlist);
	    my $id = 0;
	    foreach my $dimm (@dimms) {
		my ($dimm_size, $numanode) = @$dimm;
		next if !$dimm_size;
		$numanode = $numa_hostmap->{$numanode};
		my $hugepages_size = hugepages_size($conf, $dimm_size);
		$hugepages_topology->{$hugepages_size}->{$numanode} += hugepages_nr($dimm_size, $hugepages_size);
	    }
	} else {
	    foreach_dimm($conf, undef, $memory, $sockets, sub {
		my ($conf, undef, $name, $dimm_size, $numanode, $current_size, $memory) = @_;

		$numanode = $numa_hostmap->{$numanode};

		my $hugepages_size = hugepages_size($conf, $dimm_size);
		$hugepages_topology->{$hugepages_size}->{$numanode} += hugepages_nr($dimm_size, $hugepages_size);
	    });
	}
    }

    return $hugepages_topology;
}

sub hugepages_host_topology {

    #read host hugepages
    my $hugepages_host_topology = {};

    dir_glob_foreach("/sys/devices/system/node/", 'node(\d+)', sub {
	my ($nodepath, $numanode) = @_;

	dir_glob_foreach("/sys/devices/system/node/$nodepath/hugepages/", 'hugepages\-(\d+)kB', sub {
	    my ($hugepages_path, $hugepages_size) = @_;

	    $hugepages_size = $hugepages_size / 1024;
	    my $hugepages_nr = PVE::Tools::file_read_firstline("/sys/devices/system/node/$nodepath/hugepages/$hugepages_path/nr_hugepages");
	    $hugepages_host_topology->{$hugepages_size}->{$numanode} = $hugepages_nr;
        });
    });

    return $hugepages_host_topology;
}

sub hugepages_allocate {
    my ($hugepages_topology, $hugepages_host_topology) = @_;

    #allocate new hupages if needed
    foreach my $size (sort keys %$hugepages_topology) {

	my $nodes = $hugepages_topology->{$size};

	foreach my $numanode (keys %$nodes) {

	    my $hugepages_size = $size * 1024;
	    my $hugepages_requested = $hugepages_topology->{$size}->{$numanode};
	    my $path = "/sys/devices/system/node/node${numanode}/hugepages/hugepages-${hugepages_size}kB/";
	    my $hugepages_free = PVE::Tools::file_read_firstline($path."free_hugepages");
	    my $hugepages_nr = PVE::Tools::file_read_firstline($path."nr_hugepages");

	    if ($hugepages_requested > $hugepages_free) {
		my $hugepages_needed = $hugepages_requested - $hugepages_free;
		PVE::ProcFSTools::write_proc_entry($path."nr_hugepages", $hugepages_nr + $hugepages_needed);
		#verify that is correctly allocated
		$hugepages_free = PVE::Tools::file_read_firstline($path."free_hugepages");
		if ($hugepages_free < $hugepages_requested) {
		    #rollback to initial host config
		    hugepages_reset($hugepages_host_topology);
		    die "hugepage allocation failed";
		}
	    }

	}
    }

}

sub hugepages_pre_deallocate {
    my ($hugepages_topology) = @_;

    foreach my $size (sort keys %$hugepages_topology) {

	my $hugepages_size = $size * 1024;
	my $path = "/sys/kernel/mm/hugepages/hugepages-${hugepages_size}kB/";
	my $hugepages_nr = PVE::Tools::file_read_firstline($path."nr_hugepages");
	PVE::ProcFSTools::write_proc_entry($path."nr_hugepages", 0);
    }
}

sub hugepages_reset {
    my ($hugepages_topology) = @_;

    foreach my $size (sort keys %$hugepages_topology) {

	my $nodes = $hugepages_topology->{$size};
	foreach my $numanode (keys %$nodes) {

	    my $hugepages_nr = $hugepages_topology->{$size}->{$numanode};
	    my $hugepages_size = $size * 1024;
	    my $path = "/sys/devices/system/node/node${numanode}/hugepages/hugepages-${hugepages_size}kB/";

	    PVE::ProcFSTools::write_proc_entry($path."nr_hugepages", $hugepages_nr);
	}
    }
}

sub hugepages_update_locked {
    my ($code, @param) = @_;

    my $timeout = 60; #could be long if a lot of hugepages need to be alocated

    my $lock_filename = "/var/lock/hugepages.lck";

    my $res = lock_file($lock_filename, $timeout, $code, @param);
    die $@ if $@;

    return $res;
}
1;

