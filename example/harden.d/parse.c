#include <stdio.h>
#include <string.h>

/* Parse one line of the form NAME=VALUE into name and value. */
int parse_line(const char *line, char *name, char *value) {
  const char *eq = strchr(line, '=');
  if (!eq) return -1;
  memcpy(name, line, eq - line);
  name[eq - line] = '\0';
  strcpy(value, eq + 1);
  return 0;
}
