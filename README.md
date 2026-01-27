# Multi-Engine NoC-based SoC Architecture with Ring Bus Interconnect

**High-Throughput System-on-Chip Design | SystemVerilog | Hierarchical NoC Architecture**

This repository contains the full RTL implementation of a **Multi-Engine SoC** featuring a custom **Star-Ring Hybrid Topology**. The architecture is designed to bridge a high-speed Testbench Controller with distributed E5M6 FP Processing Engines (E) using a hierarchical **Network-on-Chip (NoC)** substrate.

The design implements a custom **"Piggyback Token Passing"** protocol with **Store-and-Forward** buffering to achieve zero-latency interconnect switching and deadlock-free arbitration across multiple ring domains.

<img width="350" height="350" alt="image" src="https://github.com/user-attachments/assets/735b8149-a7d2-4af0-ab45-367d7852291b" />

---

##  Repository Structure & Ownership

This project involves end-to-end architectural design, from the central routing hub to the FP processing engines.

### 1. Interconnect Fabric (The Backbone)
| File | Description | Ownership |
| :--- | :--- | :--- |
| `hub.sv` | **Central Router**: Implements the Star topology root. Handles Global Routing (TB to Engines) and Token Mirroring logic. | **Original Design** |
| `sub_hub.sv` | **Ring Manager**: Manages local ring arbitration. Features **Store-and-Forward** buffering to inject tasks into the ring upon Token capture. | **Original Design** |
| `p25intf.sv` | System-level `struct` (RBUS), `enum`, and protocol constant definitions. | **Provided** |

### 2. Compute Cores (The Engines)
| File | Description | Ownership |
| :--- | :--- | :--- |
| `mulacc.sv` | **Processing Engine**: Implements the 3-FSM micro-architecture (Bus/FIFO/Compute) for flow control and SIMD data feeding. | **Original Design** |
| `calc_top.sv` | **SIMD Datapath**: Manages the 42-way parallel floating-point multiplier-adder tree. |  **Collaborative Design** (Optimized based on teammate's logic)  |
| `fpm.sv` | Floating-Point Multiplier with **Hidden-1 optimization** and saturation logic. | **Original Design** |
| `fpa.sv` | Floating-Point Adder utilized in the pipelined reduction tree. | **Collaborative Design** (Optimized based on teammate's logic) |

> **Note**: `p25intf.sv` was provided as part of the course infrastructure to ensure standard interface compatibility. All NoC routing logic (`hub`, `sub_hub`) and Compute micro-architectures (FSMs, Datapaths) were independently architected and implemented by me.

---

##  Key Technical Highlights

### 1. Hierarchical Star-Ring Topology
The system utilizes a two-level hierarchy to maximize bandwidth and scalability:
* **Level 1 (The Hub)**: A central router that acts as a demultiplexer, routing Write Requests from the Testbench to one of the 4 independent Engine Rings based on the Destination Device ID.
* **Level 2 (The Sub-Hubs)**: Specialized arbitrators that manage the local traffic of each ring. They decouple the global routing constraints from local ring latency, ensuring robust timing closure.



### 2. Advanced Arbitration & Flow Control
* **Store-and-Forward Buffering**: The `sub_hub` implements a task buffer (`task_buffer`) to hold incoming global requests. It waits for the local Ring Token (T=1), "captures" the bus by asserting T=0 to hold the slot, and then injects the buffered task. This prevents data loss during high-traffic congestion.
* **Token Mirroring**: The central Hub implements intelligent flow control that mirrors the Testbench's token state (Hold/Release), ensuring the test environment stays perfectly synchronized with the hardware state.
* **Initialization Sweep**: Both Hub and Sub-Hubs execute a robust "Echo Check" sequence (sending T=0 until T=0 returns) to verify ring integrity before injecting the live Token (T=1).

### 3. Micro-Architecture: The "Tri-FSM" Core
The `mulacc` engine is orchestrated by three decoupled Finite State Machines to maximize throughput:
* **Bus FSM (The Loader)**: Handles RBUS protocol decoding, address calculation, and burst mode transfers.
* **FIFO FSM (The Guard)**: Manages 8-entry asynchronous FIFOs. Features **conservative empty logic** to prevent Read-After-Write (RAW) race conditions.
* **Compute FSM (The Feeder)**: Implements a **Ping-Pong data feeding strategy**. It unpacks 1008-bit wide words into 504-bit SIMD vectors to drive the compute pipeline without stalling.



### 4. Hardware-Efficient Arithmetic (E5M6)
* **Hidden Leading 1 Optimization**: The arithmetic units (`fpm.sv`) assume a normalized input format with a hidden leading bit. This optimization removes the need for complex subnormal handling logic, significantly reducing silicon area and critical path delay.
* **Massive SIMD Parallelism**: Instantiates **42 parallel Floating-Point Multipliers** followed by a pipelined adder reduction tree, achieving single-cycle throughput once the pipeline is primed.

---

##  Verification & Results

* **Topology Validation**: Verified correct routing of packets from the Hub to specific devices (Dev 9, 11, 13, 15) across 4 different local rings.
* **Protocol Compliance**: Validated the "Token Capture & Inject" timing in `sub_hub` to ensure zero bus collisions during high-load task injection.
* **Achievement**: This implementation was recognized as the **only project in the class** to successfully complete the full hardware integration (Hub + Sub-Hubs + 5 Engines) and pass all functional verification stages.

---

##  Tools Used
* **RTL Design**: SystemVerilog
* **Simulation**: Synopsys VCS
* **Synthesis**: Synopsys Design Compiler

---

##  Author
**Yu-Kuan Lin**
* M.S. in Electrical Engineering, San José State University
* Focus: Digital IC Design, NoC Architecture, FPGA Acceleration

