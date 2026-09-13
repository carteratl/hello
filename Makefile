# Convenience wrapper around build.sh.
.PHONY: all app package notarize clean reset-state

all: package

app:
	./build.sh app

package:
	./build.sh pkg

notarize:
	./build.sh notarize

clean:
	./build.sh clean

# Development helper: clear the once-per-boot state so the movie plays again.
reset-state:
	./scripts/reset-state.sh
