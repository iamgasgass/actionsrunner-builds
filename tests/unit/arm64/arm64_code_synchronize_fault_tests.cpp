// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * IC IVAU names an address, and hardware faults it as it would a load: an
 * address the process has no translation for takes a translation fault, the
 * kernel maps the page, and the instruction runs again, so it always reaches
 * the frame it means. A software page table the kernel fills at faults has no
 * entry for a view the process never touched, such as the executable view of a
 * page another process also runs. Both engines report that fault, at the
 * instruction and not after it, and publish the code change once the page is
 * mapped.
 *
 * Cases:
 *   unmapped    IC IVAU at an address nothing maps faults for a read at that
 *               address, at the instruction, which has not retired; once the
 *               page is mapped, the instruction runs and the guest goes on.
 *   mapped      A page mapped without execute, as a writable view is, does not
 *               fault.
 *   null page   IC IVAU at the null page faults like any other unmapped page:
 *               a privileged guest can map code there, as a lazy view, and the
 *               kernel's answer to the fault (a mapping or a signal) is the
 *               architecture's.
 *   lazy-view   A writes the code through its writable view and invalidates the
 *               instruction cache at the executable view, which A has not
 *               mapped yet. The fault maps the view; B, which translated the
 *               page, then runs the new instruction.
 */
#include "arm64_cross_generation_test_support.hpp"

#include <cstdint>
#include <cstdio>
#include <memory>
#include <string_view>

namespace {

using namespace uml::testing::cross;
using uml::testing::require;

constexpr std::uint32_t ic_ivau_x1 = 0xd50b'7521U;

int failures;

void expect(bool condition, const char *engine, const char *what)
{
	if (condition)
		return;
	++failures;
	std::printf("  %s: FAIL %s\n", engine, what);
}

void unmapped_and_mapped(uml::cpu::EngineKind kind, unsigned long &next)
{
	const char *engine_label = engine_name(kind);
	const auto generation = next++;
	require(darwin_uml_static_vm_activate(generation) == 0);
	{
		uml::testing::ScratchBacking code{"uml-icfault-code.XXXXXX", page};
		uml::testing::ScratchBacking data{"uml-icfault-data.XXXXXX", page};
		const std::uint32_t words[] = {ic_ivau_x1, movz_x0(7), svc0};
		code.put(0, std::as_bytes(std::span{words}));
		const Map code_map{generation, shared_base, code.descriptor(),
			PROT_READ | PROT_EXEC, true};
		auto engine = uml::cpu::make_cpu_engine(kind);
		require(engine != nullptr);

		arm64::CpuState cpu{};
		cpu.pc = shared_base;
		cpu.registers[1] = alias_base + 0x40;
		const auto fault = run(*engine, generation, cpu);
		expect(fault.reason == uml::cpu::ExitReason::memory_fault, engine_label,
			"an unmapped IC IVAU did not fault");
		expect(fault.fault.address == alias_base + 0x40 &&
			fault.fault.access == uml::memory::MemoryAccess::read,
			engine_label, "the fault is not a read of the address");
		expect(cpu.pc == shared_base, engine_label,
			"the fault is not at the instruction");
		expect(fault.retired_instructions == 0, engine_label,
			"the instruction that faulted retired");

		/* The kernel maps the page, and the instruction runs again. */
		const Map data_map{generation, alias_base, data.descriptor(),
			PROT_READ | PROT_WRITE, false};
		const auto again = run(*engine, generation, cpu);
		expect(again.reason == uml::cpu::ExitReason::system_call &&
			cpu.registers[0] == 7, engine_label,
			"the instruction did not run once its page was mapped");

		/* A page mapped without execute, as a writable view is, is a page. */
		arm64::CpuState writable{};
		writable.pc = shared_base;
		writable.registers[1] = alias_base;
		const auto quiet = run(*engine, generation, writable);
		expect(quiet.reason == uml::cpu::ExitReason::system_call &&
			writable.registers[0] == 7, engine_label,
			"an IC IVAU at a writable view faulted");

		/* The null page is a page like another: the kernel decides whether
		 * something maps it. */
		arm64::CpuState null_page{};
		null_page.pc = shared_base;
		null_page.registers[1] = 0;
		const auto null_run = run(*engine, generation, null_page);
		expect(null_run.reason == uml::cpu::ExitReason::memory_fault &&
			null_run.fault.address == 0 &&
			null_run.fault.access == uml::memory::MemoryAccess::read,
			engine_label, "an IC IVAU at the null page did not fault for a read");
		expect(null_page.pc == shared_base &&
			null_run.retired_instructions == 0, engine_label,
			"the null-page fault is not at the instruction, unretired");
	}
	require(darwin_uml_static_vm_destroy(generation) == 0);
}

void lazy_view(uml::cpu::EngineKind kind, bool second_vcpu,
	unsigned long &next)
{
	const char *engine_label = engine_name(kind);
	const auto b = next++;
	const auto a = next++;
	require(darwin_uml_static_vm_activate(b) == 0);
	require(darwin_uml_static_vm_activate(a) == 0);
	bool fresh = false;
	{
		uml::testing::ScratchBacking shared{"uml-icfault-shared.XXXXXX", page};
		uml::testing::ScratchBacking writer{"uml-icfault-writer.XXXXXX", page};
		const std::uint32_t old_words[] = {movz_x0(1), svc0};
		shared.put(0, std::as_bytes(std::span{old_words}));
		writer.put(0, std::as_bytes(std::span{writer_program_other_view}));
		auto engine_b = uml::cpu::make_cpu_engine(kind);
		require(engine_b != nullptr);

		const Map b_code{b, shared_base, shared.descriptor(),
			PROT_READ | PROT_EXEC, true};
		const Map a_view{a, shared_base, shared.descriptor(),
			PROT_READ | PROT_WRITE, false};
		const Map a_writer{a, writer_base, writer.descriptor(),
			PROT_READ | PROT_EXEC, true};
		require(call(*engine_b, b, shared_base) == 1);
		require(call(*engine_b, b, shared_base) == 1);

		on_vcpu(kind, *engine_b, second_vcpu, [&](uml::cpu::CpuEngine &engine) {
			arm64::CpuState cpu{};
			cpu.pc = writer_base;
			cpu.registers[1] = movz_x0(2);
			cpu.registers[2] = shared_base;
			cpu.registers[3] = alias_base;
			const auto first = run(engine, a, cpu);
			expect(first.reason == uml::cpu::ExitReason::memory_fault &&
				first.fault.address == alias_base, engine_label,
				"the writer's IC IVAU at an unmapped view did not fault");
			/* The kernel maps the executable view; the writer goes on. */
			const Map a_alias{a, alias_base, shared.descriptor(),
				PROT_READ | PROT_EXEC, true};
			const auto second = run(engine, a, cpu);
			expect(second.reason == uml::cpu::ExitReason::system_call,
				engine_label, "the writer did not finish");
		});
		fresh = call(*engine_b, b, shared_base) == 2;
	}
	require(darwin_uml_static_vm_destroy(a) == 0);
	require(darwin_uml_static_vm_destroy(b) == 0);
	expect(fresh, engine_label,
		second_vcpu ? "B kept the old code (two vCPUs)" :
			"B kept the old code (one vCPU)");
}

} // namespace

int main(int argc, char **argv)
{
	const uml::testing::RuntimeTestRoute runtime_route;
	unsigned long generation = 0x6c00;
	for_each_engine(argc > 1 ? argv[1] : "", [&](uml::cpu::EngineKind kind) {
		unmapped_and_mapped(kind, generation);
		for (const bool second_vcpu : {false, true})
			lazy_view(kind, second_vcpu, generation);
	});
	std::printf("arm64-code-synchronize-fault: %d failure(s)\n", failures);
	return failures == 0 ? 0 : 1;
}
