CC_MINGW    = i686-w64-mingw32-gcc
ifeq ($(OS),Windows_NT)
    STRIP_MINGW = strip
else
    STRIP_MINGW = i686-w64-mingw32-strip
endif

TARGET = probe_marker.asi
SRC    = probe_marker.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC_MINGW) -O2 -Wall -static-libgcc -shared -o $(TARGET) $(SRC) -lkernel32
	$(STRIP_MINGW) $(TARGET)
	@echo "Built: $(TARGET) ($$(wc -c < $(TARGET)) bytes)"

clean:
	rm -f $(TARGET)
