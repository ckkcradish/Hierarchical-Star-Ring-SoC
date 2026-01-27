// Interface file definitions for this project
// Provided by instructor
package defs;
typedef enum logic[2:0] {
    READ_REQ=0,
    WRITE_REQ=1,
    WDATA=2,
    RDATA=3,
    TOKEN_ONLY=4,
    IDLE=5,
    EMPTY=7
} CMD;

typedef struct packed {
    CMD Opcode;
    logic Token;
    logic [3:0] Source;
    logic [3:0] Destination;
    logic [1007:0] Data;
} RBUS;

typedef struct packed {
    logic [47:0] result;
    logic pushOut;
} RESULT;


typedef logic[47:0] RamAddr;
typedef logic[1007:0] RamData;
typedef logic[7:0] FifoAddr;
typedef logic[1007:0] FifoData;

typedef struct packed {
    FifoAddr wa;
    FifoData wd;
    logic write;
} FIFOWRITE;        // used by fifo memory model

typedef struct packed {
    FifoAddr ra;
    FifoData rd;
} FIFOREAD;         // used by fifo memory model

typedef enum logic[3:0] {
    ad_tb=0,
    ad_m0=8,
    ad_ma0=9,
    ad_m1=10,
    ad_ma1=11,
    ad_m2=12,
    ad_ma2=13,
    ad_m3=14,
    ad_ma3=15
} DEVICE_ADDR;

typedef struct packed {
    logic Busy;
    logic [47:0] ChainAddress;
    logic [31:0] NumGroups;
    logic [47:0] CoefAddress;
    logic [47:0] DataAddress;
} REGS;


// all intrface objects are used by UVM and other
// verification code.  Your design does not use the interfaces.
endpackage : defs
import defs::*;

interface ClkReset (input clk, inout wire reset);

    modport crin(input clk, input reset);

endinterface : ClkReset

interface Rbus;

    RBUS rbi;
    RBUS rbo;

    modport busin(input rbi);
    modport businSrc(output rbi);
    modport busout(output rbo);
    modport busoutDst(input rbo);

endinterface : Rbus

interface Results ;
    RESULT r;

    modport ResOut(output r);
    modport ResIn(input r);

endinterface : Results

interface FIFORAM ;
    FifoAddr ra,wa;
    logic write;
    FifoData rd,wd;

    modport RamIn(output wa,write,wd);
    modport RamOut(output ra,input rd);

endinterface : FIFORAM






