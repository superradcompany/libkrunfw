KERNEL_VERSION = linux-6.12.95
# Fetch stable snapshots directly so HTTP errors are visible instead of cached as tarballs.
KERNEL_REMOTE = https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/$(KERNEL_VERSION).tar.gz
KERNEL_TARBALL = tarballs/$(KERNEL_VERSION).tar.gz
KERNEL_SOURCES = $(KERNEL_VERSION)
KERNEL_PATCHES = $(shell find patches/ -name "0*.patch" | sort)
KERNEL_C_BUNDLE = kernel.c

ABI_VERSION = 5
FULL_VERSION = 5.6.0
TIMESTAMP = "Sat Jul 18 00:02:54 WAT 2026"

KERNEL_FLAGS = KBUILD_BUILD_TIMESTAMP=$(TIMESTAMP)
KERNEL_FLAGS += KBUILD_BUILD_USER=root
KERNEL_FLAGS += KBUILD_BUILD_HOST=libkrunfw
KERNEL_FLAGS += KBUILD_BUILD_VERSION=1

ifeq ($(SEV),1)
    VARIANT = -sev
    KERNEL_PATCHES += $(shell find patches-tee/ -name "0*.patch" | sort)
    WINDOWS_DEF_VARIANT = -tee
endif
ifeq ($(TDX),1)
    VARIANT = -tdx
    KERNEL_PATCHES += $(shell find patches-tee/ -name "0*.patch" | sort)
    WINDOWS_DEF_VARIANT = -tee
endif

HOSTARCH = $(shell uname -m 2>/dev/null || echo x86_64)
HOSTOS = $(shell uname -s 2>/dev/null || echo Windows_NT)
WINDOWS_HOST = $(findstring MINGW,$(HOSTOS))$(findstring MSYS,$(HOSTOS))$(findstring CYGWIN,$(HOSTOS))$(filter Windows_NT,$(HOSTOS))
ifeq ($(origin OS),command line)
    # Use the explicit OS value from command line (e.g. make OS=Windows)
else
UNAME_S = $(HOSTOS)
ifeq ($(findstring MINGW,$(UNAME_S)),MINGW)
	OS = Windows
else ifeq ($(findstring MSYS,$(UNAME_S)),MSYS)
	OS = Windows
else ifeq ($(findstring CYGWIN,$(UNAME_S)),CYGWIN)
	OS = Windows
else ifeq ($(UNAME_S),Windows_NT)
	OS = Windows
else
	OS = $(UNAME_S)
endif
endif
ifeq ($(ARCH),)
	GUESTARCH := $(HOSTARCH)
	STRIP := strip
else ifeq ($(ARCH),arm64)
	GUESTARCH := aarch64
	CC := $(CROSS_COMPILE)gcc
	STRIP := $(CROSS_COMPILE)strip
else ifeq ($(ARCH),riscv)
	GUESTARCH := riscv64
	CC := $(CROSS_COMPILE)gcc
	STRIP := $(CROSS_COMPILE)strip
else
	GUESTARCH := $(ARCH)
	CC := $(CROSS_COMPILE)gcc
	STRIP := $(CROSS_COMPILE)strip
endif

ifeq ($(OS),Windows)
    VARIANT := -windows
endif

KBUNDLE_TYPE_x86_64 = vmlinux
KBUNDLE_TYPE_aarch64 = Image
KBUNDLE_TYPE_riscv64 = Image

KERNEL_BINARY_x86_64 = $(KERNEL_SOURCES)/vmlinux
KERNEL_BINARY_aarch64 = $(KERNEL_SOURCES)/arch/arm64/boot/Image
KERNEL_BINARY_riscv64 = $(KERNEL_SOURCES)/arch/riscv/boot/Image

KRUNFW_BINARY_Linux = libkrunfw$(VARIANT).so.$(FULL_VERSION)
KRUNFW_SONAME_Linux = libkrunfw$(VARIANT).so.$(ABI_VERSION)
KRUNFW_BASE_Linux = libkrunfw$(VARIANT).so
SONAME_Linux = -Wl,-soname,$(KRUNFW_SONAME_Linux)

KRUNFW_BINARY_Darwin = libkrunfw.$(ABI_VERSION).dylib
KRUNFW_SONAME_Darwin = libkrunfw.$(ABI_VERSION).dylib
KRUNFW_BASE_Darwin = libkrunfw.dylib
SONAME_Darwin =

KRUNFW_BINARY_Windows = libkrunfw$(VARIANT).dll
KRUNFW_IMPLIB_Windows = libkrunfw$(VARIANT).lib
KRUNFW_DEF_Windows = libkrunfw$(WINDOWS_DEF_VARIANT).def

LIBDIR_Linux = $(shell if [ -e /etc/debian_version ]; then echo 'lib/$(HOSTARCH)-linux-gnu'; else echo lib64; fi)
LIBDIR_Darwin = lib
LIBDIR_Windows = bin

ifeq ($(OS),Windows)
WINDOWS_TOOLCHAIN ?= msvc
WINDOWS_SECTION_ALIGN = 65536
ifeq ($(WINDOWS_TOOLCHAIN),msvc)
ifeq ($(origin CC),default)
	CC = cl
endif
	WINDOWS_SHARED_CMD = $(CC) /nologo /LD /DABI_VERSION=$(ABI_VERSION) /Fe:$@ $(KERNEL_C_BUNDLE) $(QBOOT_C_BUNDLE) $(INITRD_C_BUNDLE) /link /DEF:$(KRUNFW_DEF_Windows) /IMPLIB:$(KRUNFW_IMPLIB_Windows) /ALIGN:$(WINDOWS_SECTION_ALIGN) /SECTION:.krunfw,R,ALIGN=$(WINDOWS_SECTION_ALIGN)
else
ifeq ($(origin CC),default)
	CC = x86_64-w64-mingw32-gcc
endif
	WINDOWS_SHARED_CMD = $(CC) -DABI_VERSION=$(ABI_VERSION) -shared -Wl,--section-alignment,$(WINDOWS_SECTION_ALIGN) -o $@ $(KERNEL_C_BUNDLE) $(QBOOT_C_BUNDLE) $(INITRD_C_BUNDLE) $(KRUNFW_DEF_Windows)
endif
endif

ifeq ($(PREFIX),)
    PREFIX := /usr/local
endif

ifeq ($(SEV),1)
    QBOOT_BINARY = qboot/sev/bios.bin
    QBOOT_C_BUNDLE = qboot.c
    INITRD_BINARY = initrd/initrd.gz
    INITRD_C_BUNDLE = initrd.c
endif
ifeq ($(TDX),1)
    QBOOT_BINARY = qboot/tdx/bios.bin
    QBOOT_C_BUNDLE = qboot.c
    INITRD_BINARY = initrd/initrd.gz
    INITRD_C_BUNDLE = initrd.c
endif

.PHONY: all install clean

all: $(KRUNFW_BINARY_$(OS))

$(KERNEL_TARBALL):
	@mkdir -p tarballs
	curl --fail --location --retry 5 --retry-delay 2 $(KERNEL_REMOTE) -o $(KERNEL_TARBALL)

$(KERNEL_SOURCES): $(KERNEL_TARBALL)
	tar xf $(KERNEL_TARBALL)
	./scripts/apply-kernel-patches.sh $(KERNEL_SOURCES) $(KERNEL_PATCHES)
	cp config-libkrunfw$(VARIANT)_$(GUESTARCH) $(KERNEL_SOURCES)/.config
	cd $(KERNEL_SOURCES) ; $(MAKE) olddefconfig

$(KERNEL_BINARY_$(GUESTARCH)): $(KERNEL_SOURCES)
	cd $(KERNEL_SOURCES) ; rm -f .version ; $(MAKE) $(MAKEFLAGS) $(KERNEL_FLAGS)

ifeq ($(OS),Windows)
ifneq ($(WINDOWS_HOST),)
$(KERNEL_C_BUNDLE):
	$(error Windows builds consume an existing kernel.c generated on Linux)
else
$(KERNEL_C_BUNDLE): $(KERNEL_BINARY_$(GUESTARCH))
	@echo "Generating $(KERNEL_C_BUNDLE) from $(KERNEL_BINARY_$(GUESTARCH))..."
	@python3 bin2cbundle.py --os $(OS) -t $(KBUNDLE_TYPE_$(GUESTARCH)) $(KERNEL_BINARY_$(GUESTARCH)) kernel.c
endif
else ifeq ($(OS),Darwin)
$(KERNEL_C_BUNDLE):
	@echo "Building on macOS, using ./build_in_docker.sh"
	./build_in_docker.sh
else
$(KERNEL_C_BUNDLE): $(KERNEL_BINARY_$(GUESTARCH))
	@echo "Generating $(KERNEL_C_BUNDLE) from $(KERNEL_BINARY_$(GUESTARCH))..."
	@python3 bin2cbundle.py --os $(OS) -t $(KBUNDLE_TYPE_$(GUESTARCH)) $(KERNEL_BINARY_$(GUESTARCH)) kernel.c
endif

ifeq ($(SEV),1)
$(QBOOT_C_BUNDLE): $(QBOOT_BINARY)
	@echo "Generating $(QBOOT_C_BUNDLE) from $(QBOOT_BINARY)..."
	@python3 bin2cbundle.py -t qboot $(QBOOT_BINARY) qboot.c

$(INITRD_C_BUNDLE): $(INITRD_BINARY)
	@echo "Generating $(INITRD_C_BUNDLE) from $(INITRD_BINARY)..."
	@python3 bin2cbundle.py -t initrd $(INITRD_BINARY) initrd.c
endif

ifeq ($(TDX),1)
$(QBOOT_C_BUNDLE): $(QBOOT_BINARY)
	@echo "Generating $(QBOOT_C_BUNDLE) from $(QBOOT_BINARY)..."
	@python3 bin2cbundle.py -t qboot $(QBOOT_BINARY) qboot.c

$(INITRD_C_BUNDLE): $(INITRD_BINARY)
	@echo "Generating $(INITRD_C_BUNDLE) from $(INITRD_BINARY)..."
	@python3 bin2cbundle.py -t initrd $(INITRD_BINARY) initrd.c
endif

ifeq ($(OS),Windows)
$(KRUNFW_BINARY_$(OS)): $(KERNEL_C_BUNDLE) $(QBOOT_C_BUNDLE) $(INITRD_C_BUNDLE) $(KRUNFW_DEF_Windows)
	$(WINDOWS_SHARED_CMD)
else
$(KRUNFW_BINARY_$(OS)): $(KERNEL_C_BUNDLE) $(QBOOT_C_BUNDLE) $(INITRD_C_BUNDLE)
	$(CC) -fPIC -DABI_VERSION=$(ABI_VERSION) -shared $(SONAME_$(OS)) -o $@ $(KERNEL_C_BUNDLE) $(QBOOT_C_BUNDLE) $(INITRD_C_BUNDLE)
ifeq ($(OS),Linux)
	$(STRIP) $(KRUNFW_BINARY_$(OS))
endif
endif

install:
	install -d $(DESTDIR)$(PREFIX)/$(LIBDIR_$(OS))/
	install -m 755 $(KRUNFW_BINARY_$(OS)) $(DESTDIR)$(PREFIX)/$(LIBDIR_$(OS))/
ifeq ($(OS),Darwin)
	cd $(DESTDIR)$(PREFIX)/$(LIBDIR_$(OS))/ ; ln -sf $(KRUNFW_BINARY_$(OS)) $(KRUNFW_BASE_$(OS))
else ifeq ($(OS),Windows)
	# Windows doesn't need soname symlinks
else
	cd $(DESTDIR)$(PREFIX)/$(LIBDIR_$(OS))/ ; ln -sf $(KRUNFW_BINARY_$(OS)) $(KRUNFW_SONAME_$(OS)) ; ln -sf $(KRUNFW_SONAME_$(OS)) $(KRUNFW_BASE_$(OS))
endif

clean:
	rm -fr $(KERNEL_SOURCES) $(KERNEL_C_BUNDLE) $(QBOOT_C_BUNDLE) $(INITRD_C_BUNDLE) $(KRUNFW_BINARY_$(OS)) $(KRUNFW_IMPLIB_$(OS))
