/*
 * Hacker Disassembler Engine 64
 * Minimal x86-64 instruction length decoder with ModR/M + REX parsing.
 * Based on the public domain HDE by Vyacheslav Patkov.
 */

#ifndef HDE64_H
#define HDE64_H

#include <stdint.h>

#define F_MODRM 0x00000001
#define F_SIB 0x00000002
#define F_IMM8 0x00000004
#define F_IMM16 0x00000008
#define F_IMM32 0x00000010
#define F_IMM64 0x00000020
#define F_DISP8 0x00000040
#define F_DISP16 0x00000080
#define F_DISP32 0x00000100
#define F_PREFIX_66 0x00000200
#define F_PREFIX_67 0x00000400
#define F_PREFIX_F2 0x00000800
#define F_PREFIX_F3 0x00001000
#define F_PREFIX_SEG 0x00002000
#define F_PREFIX_LOCK 0x00004000
#define F_PREFIX_REX 0x00008000
#define F_2B 0x00010000 /* 0F prefix (two-byte opcode) */
#define F_ERROR 0x00020000

typedef struct {
    uint8_t len;
    uint8_t opcode;
    uint8_t opcode2;
    uint8_t modrm;
    uint8_t sib;
    uint8_t rex;
    uint32_t flags;
} hde64s;

#ifdef __cplusplus
extern "C" {
#endif

unsigned int hde64_disasm(const void* code, hde64s* hs);

#ifdef __cplusplus
}
#endif

#endif /* HDE64_H */
