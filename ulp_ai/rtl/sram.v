// 단일포트 동기 SRAM (바이트 enable, 읽기 1사이클 지연). 실제로는 리텐션 지원 매크로.
module sram #(parameter WORDS = 2048, parameter INIT = "")(
    input clk, input req, input we, input [3:0] be,
    input [$clog2(WORDS)-1:0] addr, input [31:0] wdata, output reg [31:0] rdata
);
    reg [31:0] mem [0:WORDS-1];
    integer i;
    initial if (INIT != "") $readmemh(INIT, mem);
    always @(posedge clk) if (req) begin
        if (we) for (i = 0; i < 4; i = i + 1) if (be[i]) mem[addr][8*i +: 8] <= wdata[8*i +: 8];
        rdata <= mem[addr];   // 요청이 없으면 출력 유지 → 불필요한 토글 없음
    end
endmodule
