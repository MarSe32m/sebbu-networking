#ifndef C_SEBBU_NETWORKING_H
#define C_SEBBU_NETWORKING_H

#if defined(__linux__)

#define _GNU_SOURCE
#include <sched.h>
#include <pthread.h>

void cpu_zero(cpu_set_t* set);

void cpu_set(int cpu, cpu_set_t* set);

#elif defined(_WIN32)

#endif //_WIN32
#endif // C_SEBBU_NETWORKING_H
