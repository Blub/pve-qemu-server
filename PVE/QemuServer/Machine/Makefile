SOURCES := i440fx.pm \
	   q35.pm \
	   arm_virt.pm \

.PHONY: install
install:
	for i in ${SOURCES}; do install -D -m 0644 $$i ${DESTDIR}${PERLDIR}/PVE/QemuServer/Machine/$$i; done
