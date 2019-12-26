#include <stdio.h>

int main(int argc, char *argv[])
{
    // let's make our own array of strings
    char *states[] = {
        "California", "Oregon",
        "Washington", NULL
    };
    int num_states = 4;

    argv[1] = states[1];

    // go through each string in argv
    // why am I skipping argv[0]?
    for(int i = 1; i < argc; i++) {
        printf("arg %d: %s\n", i, argv[i]);
    }


    for(int i = 0; i <= num_states; i++) {
        printf("state %d: %s\n", i, states[i]);
    }

    return 0;
}
