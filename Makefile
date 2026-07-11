# Top-level Makefile — builds every mod under mods/
#
# Each mod is a self-contained subdirectory with its own Makefile.
# See README.md for prerequisites (32-bit MinGW cross-compiler).

MODS := $(patsubst mods/%/Makefile,%,$(wildcard mods/*/Makefile))

.PHONY: all clean $(MODS)

all: $(MODS)

$(MODS):
	$(MAKE) -C mods/$@

clean:
	@for m in $(MODS); do $(MAKE) -C mods/$$m clean; done
