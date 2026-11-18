// Posts com.imodcommission.nig.dump: the app in front writes its view tree
// to <its tmp>/nig-dump.txt. Build: clang -arch arm64e Tools/nigdump.c -o /tmp/nigdump
#include <notify.h>
#include <stdio.h>

int main(void) {
    uint32_t status = notify_post("com.imodcommission.nig.dump");
    printf("notify_post status=%u\n", status);
    return status == NOTIFY_STATUS_OK ? 0 : 1;
}
