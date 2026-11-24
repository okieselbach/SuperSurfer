// C interface of the SuperSurfer core (src/ffi.rs), linked into the app as a
// static library. Requests and replies are JSON; see src/engine.rs for the
// operations and their fields.

#ifndef SUPERSURFER_H
#define SUPERSURFER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Sends one JSON request to the routing engine and returns the JSON reply.
/// The caller owns the reply and releases it with supersurfer_free().
char *_Nullable supersurfer_call(const char *_Nonnull request_json);

/// Releases a reply returned by supersurfer_call(). NULL is ignored.
void supersurfer_free(char *_Nullable reply);

/// Runs the SuperSurfer command line and returns the process exit code.
/// `args_json` is a JSON array of strings: the arguments without the program
/// name, e.g. ["test", "https://example.com"].
int32_t supersurfer_cli(const char *_Nonnull args_json);

#ifdef __cplusplus
}
#endif

#endif
