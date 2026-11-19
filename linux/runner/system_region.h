#ifndef RUNNER_SYSTEM_REGION_H_
#define RUNNER_SYSTEM_REGION_H_

#include <flutter_linux/flutter_linux.h>

// Backs the `kapynotes/region` channel:
//
//   region  -> String?, the territory of the locale the session formats
//              numbers with (LC_NUMERIC), separate from the language the app
//              is read in
typedef struct _SystemRegion SystemRegion;

SystemRegion* system_region_new(FlBinaryMessenger* messenger);

void system_region_free(SystemRegion* region);

#endif  // RUNNER_SYSTEM_REGION_H_
