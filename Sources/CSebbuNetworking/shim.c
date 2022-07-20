//
//  shim.c
//  
//
//  Created by Sebastian Toivonen on 20.7.2022.
//

#include "CSebbuNetworking.h"

#if defined(__linux__)
void cpu_zero(cpu_set_t* set) {
    CPU_ZERO(set);
}

void cpu_set(int cpu, cpu_set_t* set) {
    CPU_SET(cpu, set);
}
#elif defined(_WIN32)

#endif
