#include <stdio.h>

int main(int argc, char *argv[]) {
    int ages[] = {23, 43, 12, 89, 2};
    char *names[] = {
        "Alan", "Frank",
        "Mary", "John", "Lisa"
    };

    int count = sizeof(ages) / sizeof(int);
    int i = 0;

    for(i =0; i < count; i++) {
        printf("%s has %d years alive.\n", names[i], ages[i]);
    }

    printf("---\n");

    int *cur_age = ages;
    char **cur_name = names;

    /*for(i = 0; i < count; i++) {*/
        /*printf("%s is %d years old.\n", *(cur_name+i), *(cur_age+i));*/
    /*}*/

    /*printf("---\n");*/

    /*for(i = 0; i < count; i++) {*/
        /*printf("%s is %d years old again.\n", cur_name[i], cur_age[i]);*/
    /*}*/

    /*printf("---\n");*/

    /*for(cur_name = names, cur_age = ages;*/
            /*(cur_age - ages) < count;*/
            /*cur_name++, cur_age++)*/
    /*{*/
        /*printf("%s lived %d years so far.\n",*/
                /**cur_name, *cur_age);*/
    /*}*/

    for(i = 0; i < count; i++) {
        printf("ages[i]: %d\n ages+i %p\n *(ages+i) %d\n ", ages[i], ages+i, *(ages+i));
        printf("cur_age[i]: %d\n cur_age+i %p\n *(cur_age+i) %d\n ", cur_age[i], cur_age+i, *(cur_age+i));
        printf("names[i]: %s\n names+i %p\n *(names+i) %s\n ", names[i], names+i, *(names+i));
        printf("cur_name[i]: %s\n cur_name+i %p\n *(cur_name+i) %s\n ", cur_name[i], cur_name+i, *(cur_name+i));
    }

    return 0;
}
