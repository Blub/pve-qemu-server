package PVE::QemuServer::Machine::q35;

use strict;
use warnings;

use base 'PVE::QemuServer::Machine';

# Parts of this machine layout come from
#   /usr/share/qemu-server/pve-q35.cfg
#
# device kvmvapic
# device kvmclock
# device cfi.pflash01: 0x1e0 blocks of 0x1000
# device cfi.pflash01: 0x20 blocks of 0x1000
# device fw_cfg_io
# device q35-pcihost {
#   bus pcie.0: type PCIE {
#     00.0: device mch: host bridge
#     01.0: device VGA
#     1a.0: device ich9-usb-uhci4: USB controller { master = ehci-2.0 }
#     1a.1: device ich9-usb-uhci5: USB controller { master = ehci-2.0 }
#     1a.2: device ich9-usb-uhci6: USB controller { master = ehci-2.0 }
#     1a.7: device ich9-usb-ehci2: USB controller {
#       bus ehci-2.0
#     }
#     1b.0: device ich9-intel-hda: Audio controller
#     1c.0: device ioh3420: PCI bridge {
#       bus ich9-pcie-port-1: type PCIE
#     }
#     1c.1: device ioh3420: PCI bridge {
#       bus ich9-pcie-port-2: type PCIE
#     }
#     1c.2: device ioh3420: PCI bridge {
#       bus ich9-pcie-port-3: type PCIE
#     }
#     1c.3: device ioh3420: PCI bridge {
#       bus ich9-pcie-port-4: type PCIE
#     }
#     1d.0: device ich9-usb-uhci1: USB controller { master = ehci.0 }
#     1d.1: device ich9-usb-uhci2: USB controller { master = ehci.0 }
#     1d.2: device ich9-usb-uhci3: USB controller { master = ehci.0 }
#     1d.7: device ich9-usb-ehci1: USB controller {
#       bus ehci.0: type usb-bus
#     }
#     1e.0: device i82801b11-bridge: PCI bridge {
#       bus pcidmi: type PCI {
#         01.0: device pci-bridge {
#           bus pci.0: type PCI
#         }
#         02.0: device pci-bridge {
#           bus pci.1: type PCI
#         }
#         03.0: device pci-bridge {
#           bus pci.2: type PCI
#         }
#       }
#     }
#     1f.0: device ICH9-LPC: ISA bridge {
#       bus isa.0: type ISA {
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
#       }
#     }
#     1f.2: ich9-ahci: SATA controller {
#       bus ide.{0..5}: type IDE
#     }
#     1f.3: ICH9 SMB: SMBuss {
#       bus i2c: type i2c-bus {
#         80..87: device smbus-eeprom
#       }
#     }
#   }
# }
# device kvm-ioapic
# device hpet

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
};

# FIXME: return '/usr/bin/qemu-system-x86_64';
sub qemu_cmd        { return '/usr/bin/kvm'; }
sub balloon_device  { return 'virtio-balloon-pci' }
sub serial_device   { return 'isa-serial' }
sub parallel_device { return 'isa-parallel' }

sub new {
    my ($class) = @_;
    my $self = {
	buses => {
	    'pci.0' => {
		internal => 1,
		slot_property => 'addr',
		slots => 0x20,
	    },
	    'pci.1' => {
		internal => 1,
		slot_property => 'addr',
		slots => 0x20,
	    },
	    'pci.2' => {
		internal => 1,
		slot_property => 'addr',
		slots => 0x20,
	    },
	},
	args => [
	    '-boot', 'menu=on,strict=on,reboot-timeout=1000,splash=/usr/share/qemu-server/bootsplash.jpg',
	    '-readconfig', '/usr/share/qemu-server/pve-q35.cfg',
	],
    };
    return bless $self, $class;
}

1;
