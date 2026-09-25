/*
 * The ArkTrace CLI stand-in the trace-summary Job oracle runs
 * (`JobRunAnalyzerOracleContractTests/testSwiftRunsTheSharedTraceSummaryJobs`)
 * and the Rust replay `job_run_trace_summary` runs again. It is checked in
 * compiled, as `arktrace` (`cc -Os -o arktrace arktrace.c`), so both runtimes
 * run the same bytes under one SHA-256; a Mach-O executable, so a verified
 * canonical-path launch can prove its first mapping.
 *
 * Each run appends its argument zero and its arguments to `calls.log`, each
 * followed by U+001F and the run by a newline; its environment is not
 * recorded, since the base each runtime gives a child is a declared
 * difference. The first line of the file its last argument names chooses
 * its answer: `signal` kills itself, `big` prints 9 MiB of spaces, and any
 * other name writes `answers/<name>.stdout` and `answers/<name>.stderr` as
 * they are, when present, and exits with the number in `answers/<name>.exit`
 * (0 when there is none).
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ROOT "/private/tmp/arkdeck-job-plan-oracle/arktrace"

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
    fprintf(log, "\n");
    fclose(log);
  }
  char mode[64] = "";
  FILE *source = argc > 1 ? fopen(argv[argc - 1], "rb") : NULL;
  if (source == NULL || fgets(mode, sizeof mode, source) == NULL) return 66;
  fclose(source);
  mode[strcspn(mode, "\n")] = '\0';
  for (const char *character = mode; *character != '\0'; character++) {
    if ((*character < 'a' || *character > 'z') && (*character < 'A' || *character > 'Z')) return 65;
  }
  if (strcmp(mode, "signal") == 0) {
    raise(SIGKILL);
  }
  if (strcmp(mode, "big") == 0) {
    static char spaces[1024 * 1024];
    memset(spaces, ' ', sizeof spaces);
    for (int index = 0; index < 9; index++) fwrite(spaces, 1, sizeof spaces, stdout);
    fflush(stdout);
    return 0;
  }
  char path[256];
  snprintf(path, sizeof path, ROOT "/answers/%s.stdout", mode);
  copy(path, stdout);
  snprintf(path, sizeof path, ROOT "/answers/%s.stderr", mode);
  copy(path, stderr);
  int code = 0;
  snprintf(path, sizeof path, ROOT "/answers/%s.exit", mode);
  FILE *exit_file = fopen(path, "rb");
  if (exit_file != NULL) {
    if (fscanf(exit_file, "%d", &code) != 1) code = 0;
    fclose(exit_file);
  }
  fflush(stdout);
  fflush(stderr);
  return code;
}
