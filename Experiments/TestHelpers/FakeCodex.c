// Synthetic JSON-RPC peer, compiled only into the unit-test bundle. It never
// uses credentials, account files, network APIs or a shell interpreter.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    char *line = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, stdin) >= 0) {
        char *key = strstr(line, "\"id\"");
        char *colon = key ? strchr(key, ':') : NULL;
        if (!colon) continue;
        long id = strtol(colon + 1, NULL, 10);
        const char *result = NULL;
        if (strstr(line, "initialize")) result = "{\"protocolVersion\":\"2\"}";
        else if (strstr(line, "rateLimits") && strstr(line, "read")) result = "{\"rateLimits\":{\"limitId\":\"codex\",\"limitName\":\"Codex\",\"planType\":\"pro\",\"primary\":{\"usedPercent\":42,\"windowDurationMins\":300,\"resetsAt\":2000000000}}}";
        else if (strstr(line, "usage") && strstr(line, "read")) result = "{\"summary\":{\"lifetimeTokens\":1234},\"dailyUsageBuckets\":[]}";
        else if (strstr(line, "account") && strstr(line, "read")) result = "{\"account\":{\"type\":\"chatgpt\",\"planType\":\"pro\",\"email\":\"discard@example.test\"},\"requiresOpenaiAuth\":true}";
        if (result) {
            printf("{\"jsonrpc\":\"2.0\",\"id\":%ld,\"result\":%s}\n", id, result);
            fflush(stdout);
        }
    }
    free(line);
    return 0;
}
