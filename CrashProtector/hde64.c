/*
 * Hacker Disassembler Engine 64 - minimal implementation
 * Decodes x86-64 instruction length + ModR/M + REX for common instructions.
 *
 * For a full implementation see: https://github.com/iPower/hde64
 */

#include "hde64.h"

#include <string.h>

/*
 * Opcode table flags:
 * Bit 0 = has ModR/M
 * Bit 1 = has immediate byte
 * Bit 2 = has immediate word/dword (affected by 66h prefix)
 */
#define C_MODRM 1
#define C_IMM8 2
#define C_IMM66 4 /* imm16 with 66h prefix, else imm32 */
#define C_NONE 0

/* One-byte opcode map (256 entries) */
static const uint8_t op_table[256] = {
    /* 00-07 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_IMM8,
    C_IMM66,
    C_NONE,
    C_NONE,
    /* 08-0F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_IMM8,
    C_IMM66,
    C_NONE,
    C_NONE,
    /* 10-17 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_IMM8,
    C_IMM66,
    C_NONE,
    C_NONE,
    /* 18-1F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_IMM8,
    C_IMM66,
    C_NONE,
    C_NONE,
    /* 20-27 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_IMM8,
    C_IMM66,
    C_NONE,
    C_NONE,
    /* 28-2F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_IMM8,
    C_IMM66,
    C_NONE,
    C_NONE,
    /* 30-37 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_IMM8,
    C_IMM66,
    C_NONE,
    C_NONE,
    /* 38-3F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_IMM8,
    C_IMM66,
    C_NONE,
    C_NONE,
    /* 40-4F: REX prefixes in 64-bit mode - handled separately, not real opcodes */
    /* 40-47 */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 48-4F */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 50-57 */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 58-5F */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 60-67 */ C_NONE,
    C_NONE,
    C_MODRM,
    C_MODRM,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 68-6F */ C_IMM66,
    C_MODRM | C_IMM66,
    C_IMM8,
    C_MODRM | C_IMM8,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 70-77 */ C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    /* 78-7F */ C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    /* 80-87 */ C_MODRM | C_IMM8,
    C_MODRM | C_IMM66,
    C_MODRM | C_IMM8,
    C_MODRM | C_IMM8,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 88-8F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 90-97 */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 98-9F */ C_NONE,
    C_NONE,
    C_IMM66 | C_IMM8,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* A0-A7 */ C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* A8-AF */ C_IMM8,
    C_IMM66,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* B0-B7 */ C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    /* B8-BF */ C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    /* C0-C7 */ C_MODRM | C_IMM8,
    C_MODRM | C_IMM8,
    C_IMM8 | C_IMM8,
    C_NONE,
    C_MODRM,
    C_MODRM,
    C_MODRM | C_IMM8,
    C_MODRM | C_IMM66,
    /* C8-CF */ C_IMM8 | C_IMM8,
    C_NONE,
    C_IMM66,
    C_NONE,
    C_NONE,
    C_IMM8,
    C_NONE,
    C_NONE,
    /* D0-D7 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_IMM8,
    C_IMM8,
    C_NONE,
    C_NONE,
    /* D8-DF */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* E0-E7 */ C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    C_IMM8,
    /* E8-EF */ C_IMM66,
    C_IMM66,
    C_IMM66 | C_IMM8,
    C_IMM8,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* F0-F7 */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_MODRM,
    C_MODRM,
    /* F8-FF */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_MODRM,
    C_MODRM,
};

/* Two-byte opcode map (0F xx) */
static const uint8_t op_table_0f[256] = {
    /* 00-07 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 08-0F */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_MODRM,
    C_NONE,
    C_NONE,
    /* 10-17 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 18-1F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 20-27 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 28-2F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 30-37 */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* 38-3F */ C_MODRM,
    C_NONE,
    C_MODRM | C_IMM8,
    C_NONE,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 40-4F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 50-57 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 58-5F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 60-67 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 68-6F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 70-77 */ C_MODRM | C_IMM8,
    C_MODRM | C_IMM8,
    C_MODRM | C_IMM8,
    C_MODRM | C_IMM8,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_NONE,
    /* 78-7F */ C_MODRM,
    C_MODRM,
    C_NONE,
    C_NONE,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* 80-8F */ C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    C_IMM66,
    /* 90-9F */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* A0-A7 */ C_NONE,
    C_NONE,
    C_NONE,
    C_MODRM,
    C_MODRM | C_IMM8,
    C_MODRM,
    C_NONE,
    C_NONE,
    /* A8-AF */ C_NONE,
    C_NONE,
    C_NONE,
    C_MODRM,
    C_MODRM | C_IMM8,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* B0-B7 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* B8-BF */ C_MODRM,
    C_NONE,
    C_MODRM | C_IMM8,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* C0-C7 */ C_MODRM,
    C_MODRM,
    C_MODRM | C_IMM8,
    C_MODRM,
    C_MODRM | C_IMM8,
    C_MODRM | C_IMM8,
    C_MODRM | C_IMM8,
    C_MODRM,
    /* C8-CF */ C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    C_NONE,
    /* D0-D7 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* D8-DF */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* E0-E7 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* E8-EF */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* F0-F7 */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    /* F8-FF */ C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_MODRM,
    C_NONE,
};

unsigned int hde64_disasm(const void* code, hde64s* hs) {
    const uint8_t* p = (const uint8_t*)code;
    memset(hs, 0, sizeof(hde64s));

    int has_66 = 0;
    int has_67 = 0;

    /* --- Prefixes (including REX) --- */
    for (;;) {
        uint8_t c = *p;

        /* REX prefix: 0x40-0x4F in 64-bit mode */
        if (c >= 0x40 && c <= 0x4F) {
            hs->rex = c;
            hs->flags |= F_PREFIX_REX;
            p++;
            /* REX must be the last prefix before the opcode */
            break;
        }

        switch (c) {
            case 0x66:
                has_66 = 1;
                hs->flags |= F_PREFIX_66;
                break;
            case 0x67:
                has_67 = 1;
                hs->flags |= F_PREFIX_67;
                break;
            case 0xF0:
                hs->flags |= F_PREFIX_LOCK;
                break;
            case 0xF2:
                hs->flags |= F_PREFIX_F2;
                break;
            case 0xF3:
                hs->flags |= F_PREFIX_F3;
                break;
            case 0x26:
            case 0x2E:
            case 0x36:
            case 0x3E:
            case 0x64:
            case 0x65:
                hs->flags |= F_PREFIX_SEG;
                break;
            default:
                goto done_prefix;
        }
        p++;
    }
done_prefix:;

    /* --- Opcode --- */
    uint8_t opc = *p++;
    hs->opcode = opc;
    uint8_t flags;

    if (opc == 0x0F) {
        hs->flags |= F_2B;
        opc = *p++;
        hs->opcode2 = opc;
        flags = op_table_0f[opc];
    } else {
        flags = op_table[opc];
    }

    /* Special: F6/F7 group 3 (TEST has immediate) */
    if ((hs->opcode == 0xF6 || hs->opcode == 0xF7) && !(hs->flags & F_2B)) {
        uint8_t modrm_reg = (*p >> 3) & 7;
        if (modrm_reg == 0 || modrm_reg == 1) {
            flags |= (hs->opcode == 0xF6) ? C_IMM8 : C_IMM66;
        }
    }

    /* Special: B8-BF with REX.W = MOV reg, imm64 (the only instruction with imm64) */
    if (!(hs->flags & F_2B) && hs->opcode >= 0xB8 && hs->opcode <= 0xBF && (hs->rex & 0x08)) {
        /* REX.W + MOV r64, imm64: need 8 bytes of immediate instead of 4 */
        /* We'll handle this after the normal immediate processing by adding 4 extra bytes */
    }

    /* --- ModR/M --- */
    if (flags & C_MODRM) {
        hs->flags |= F_MODRM;
        uint8_t modrm = *p++;
        hs->modrm = modrm;

        uint8_t mod = modrm >> 6;
        uint8_t rm = modrm & 7;

        if (has_67) {
            /* 32-bit addressing in 64-bit mode */
            if (mod != 3 && rm == 4) {
                hs->flags |= F_SIB;
                hs->sib = *p++;
                rm = hs->sib & 7;
            }
            if (mod == 0) {
                if (rm == 5) {
                    hs->flags |= F_DISP32;
                    p += 4;
                }
            } else if (mod == 1) {
                hs->flags |= F_DISP8;
                p += 1;
            } else if (mod == 2) {
                hs->flags |= F_DISP32;
                p += 4;
            }
        } else {
            /* 64-bit addressing (default) */
            if (mod != 3 && rm == 4) {
                hs->flags |= F_SIB;
                hs->sib = *p++;
                rm = hs->sib & 7;
            }

            if (mod == 0) {
                if (rm == 5) { /* RIP-relative in 64-bit mode */
                    hs->flags |= F_DISP32;
                    p += 4;
                }
            } else if (mod == 1) {
                hs->flags |= F_DISP8;
                p += 1;
            } else if (mod == 2) {
                hs->flags |= F_DISP32;
                p += 4;
            }
        }
    }

    /* --- Immediates --- */
    if (flags & C_IMM8) {
        hs->flags |= F_IMM8;
        p += 1;
    }
    if (flags & C_IMM66) {
        if (has_66) {
            hs->flags |= F_IMM16;
            p += 2;
        } else {
            hs->flags |= F_IMM32;
            p += 4;
        }
    }

    /* Special: MOV r64, imm64 (REX.W + B8-BF) needs 8 bytes total immediate */
    if (!(hs->flags & F_2B) && hs->opcode >= 0xB8 && hs->opcode <= 0xBF && (hs->rex & 0x08)) {
        /* The C_IMM66 path above added 4 bytes (as imm32).
           For imm64 we need 4 more. */
        hs->flags |= F_IMM64;
        p += 4;
    }

    hs->len = (uint8_t)(p - (const uint8_t*)code);
    if (hs->len == 0 || hs->len > 15) {
        hs->flags |= F_ERROR;
        hs->len = 1;
    }

    return hs->len;
}
