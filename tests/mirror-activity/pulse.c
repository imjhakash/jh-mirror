#include "control_msg.h"
#include <assert.h>
int main(void) {
    struct sc_control_msg message={.type=SC_CONTROL_MSG_TYPE_JH_KEEP_ACTIVE};
    uint8_t bytes[SC_CONTROL_MSG_MAX_SIZE]={0};
    assert(sc_control_msg_serialize(&message,bytes)==1 && bytes[0]==200);
    assert(sc_control_msg_is_droppable(&message));
    message.type=SC_CONTROL_MSG_TYPE_JH_RELEASE_DISPLAY;
    assert(sc_control_msg_serialize(&message,bytes)==1 && bytes[0]==201);
    sc_control_msg_destroy(&message);
    return 0;
}
