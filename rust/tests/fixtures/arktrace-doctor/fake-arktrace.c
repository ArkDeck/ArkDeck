/*
 * The ArkTrace CLI stand-in the ArkTrace doctor oracle compiles into a
 * bundle (`ArkTraceDoctorOracleContractTests`, and the Rust replay
 * `arktrace_doctor`). A Mach-O executable, so a verified canonical-path
 * launch can prove its first mapping. Each run appends its argument zero,
 * its arguments and its two home variables to `calls.log`, each followed by
 * U+001F and the line by a newline; then it writes `stdout` and `stderr` as
 * they are and exits with the number in `exit` (0 when there is none).
 */
#include <stdio.h>
#include <stdlib.h>

#define ROOT "/private/tmp/arkdeck-arktrace-oracle/doctor"

static void copy(const char *path, FILE *to) {
  FILE *from = fopen(path, "rb");
  if (from == NULL) return;
  char buffer[65536];
  size_t count;
  while ((count = fread(buffer, 1, sizeof buffer, from)) > 0) fwrite(buffer, 1, count, to);
  fclose(from);
}

int main(int argc, char **argv) {
  FILE *log = fopen(ROOT "/calls.log", "ab");
  if (log != NULL) {
    for (int index = 0; index < argc; index++) fprintf(log, "%s\x1f", argv[index]);
    const char *home = getenv("HOME");
    const char *fixed = getenv("CFFIXED_USER_HOME");
    fprintf(log, "HOME=%s\x1f" "CFFIXED_USER_HOME=%s\x1f\n", home ? home : "-", fixed ? fixed : "-");
    fclose(log);
  }
  copy(ROOT "/stdout", stdout);
  copy(ROOT "/stderr", stderr);
  int code = 0;
  FILE *exit_file = fopen(ROOT "/exit", "rb");
  if (exit_file != NULL) {
    if (fscanf(exit_file, "%d", &code) != 1) code = 0;
    fclose(exit_file);
  }
  fflush(stdout);
  fflush(stderr);
  return code;
}
