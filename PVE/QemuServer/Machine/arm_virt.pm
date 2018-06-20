package PVE::QemuServer::Machine::arm_virt;

use strict;
use warnings;

use base 'PVE::QemuServer::Machine';

# device cfi.pflash01: 0x100 blocks of 0x40000 = 64M
# device cfi.pflash01: 0x100 blocks of 0x40000 = 64M
# device kvm-arm-gic
# device arm-gicv2m
# device pl011: main serial port
# device pl031: ?
# device gpex-pcihost {
#   bus pcie.0 {
#     00.0: device gpex-root: host bridge
#     rest open
#   }
# }
# device pl061
# device gpio-key
# device virtio-mmio [i = 0..31] {
#   bus virtio-mmio-bus.$i
# }
# device fw_cfg_mem
# device platform_bus_device

sub add_ide_disk {
    my ($self, $index, $drivename, $bootindex, %options) = @_;
    die "IDE disks are not supported on 'virt' machines on aarch64\n";
}

1;
