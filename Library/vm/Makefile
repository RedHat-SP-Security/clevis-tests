# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Makefile of /CoreOS/clevis/Library/vm
#   Description: A set of helpers for testing with VMs.
#   Author: Sergio Correia <scorreia@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2022 Red Hat, Inc. All rights reserved.
#
#   This copyrighted material is made available to anyone wishing
#   to use, modify, copy, or redistribute it subject to the terms
#   and conditions of the GNU General Public License version 2.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE. See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public
#   License along with this program; if not, write to the Free
#   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
#   Boston, MA 02110-1301, USA.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

export TEST=/CoreOS/clevis/Library/vm
export TESTVERSION=1.0

BUILT_FILES=

FILES=$(METADATA) test.sh lib.sh Makefile

.PHONY: all install download clean

run: $(FILES) build
	./test.sh

build: $(BUILT_FILES)
	test -x test.sh || chmod a+x test.sh

clean:
	rm -f *~ $(BUILT_FILES)


include /usr/share/rhts/lib/rhts-make.include

$(METADATA): Makefile
	@echo "Owner:           Sergio Correia <scorreia@redhat.com>" > $(METADATA)
	@echo "Name:            $(TEST)" >> $(METADATA)
	@echo "TestVersion:     $(TESTVERSION)" >> $(METADATA)
	@echo "Path:            $(TEST_DIR)" >> $(METADATA)
	@echo "Description:     A set of helpers for testing with VMs." >> $(METADATA)
	@echo "Type:            Library" >> $(METADATA)
	@echo "Requires:        openssh-clients" >> $(METADATA)
	@echo "TestTime:        10m" >> $(METADATA)
	@echo "Provides:        library(clevis/vm)" >> $(METADATA)
	@echo "License:         GPLv2" >> $(METADATA)

	rhts-lint $(METADATA)
