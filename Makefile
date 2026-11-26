# MWT's own NIF (c_src), built by elixir_make as part of mix compile:
# MWTClient.ProcessGuard. elixir_make sets MIX_APP_PATH and
# ERTS_INCLUDE_DIR.
PRIV := $(MIX_APP_PATH)/priv
NIF := $(PRIV)/process_guard.so

CFLAGS ?= -O2
CFLAGS += -std=gnu11 -Wall -Wextra -Werror -fPIC -I"$(ERTS_INCLUDE_DIR)"
LDFLAGS += -shared

all: $(NIF)

$(NIF): c_src/process_guard.c
	@mkdir -p "$(PRIV)"
	$(CC) $(CFLAGS) $(LDFLAGS) -o "$@" $<

clean:
	rm -f "$(NIF)"

.PHONY: all clean
