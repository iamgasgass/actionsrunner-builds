/* The few Mach-O definitions husk-tl-codesign.c uses, for building it on Linux (tools/codesign-test.c). */
#pragma once
#include <stdint.h>
#define MH_MAGIC_64 0xfeedfacfu
#define MH_DYLIB 6
#define LC_SEGMENT_64 0x19
#define LC_CODE_SIGNATURE 0x1d
#define LC_ID_DYLIB 0xd
#define VM_PROT_READ 1
#define VM_PROT_WRITE 2
#define VM_PROT_EXECUTE 4
struct mach_header_64 { uint32_t magic; int32_t cputype, cpusubtype; uint32_t filetype, ncmds, sizeofcmds, flags, reserved; };
struct load_command { uint32_t cmd, cmdsize; };
struct segment_command_64 { uint32_t cmd, cmdsize; char segname[16]; uint64_t vmaddr, vmsize, fileoff, filesize;
                            int32_t maxprot, initprot; uint32_t nsects, flags; };
struct linkedit_data_command { uint32_t cmd, cmdsize, dataoff, datasize; };
union lc_str { uint32_t offset; };
struct dylib { union lc_str name; uint32_t timestamp, current_version, compatibility_version; };
struct dylib_command { uint32_t cmd, cmdsize; struct dylib dylib; };
