#!/usr/bin/env bash
# Shared read-only SQL for repository and customer validation. Arguments are internal constants.
demo_read_query() {
  printf "SELECT count() FROM demo.%s WHERE length(payload) > 0 FORMAT TabSeparatedRaw" "$1"
}
demo_placement_query() {
  printf "SELECT count() > 0 AND countIf(disk_name != '%s') = 0 FROM system.parts WHERE database = 'demo' AND table = '%s' AND active FORMAT TabSeparatedRaw" "$2" "$1"
}
