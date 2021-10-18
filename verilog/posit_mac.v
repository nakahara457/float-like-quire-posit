`timescale 1ns / 1ns
module posit_mac(IN1, IN2, BIAS, MAC_EN, PURGE, RESULT_REQ_PLS, BIAS_EN, CLK, RESET, OUT);

function [31:0] log2;
input reg [31:0] value;
	begin
	value = value-1;
	for (log2=0; value>0; log2=log2+1)
        	value = value>>1;
      	end
endfunction

parameter N = 8;
parameter Bs = log2(N);
parameter es = 1;
parameter bias = (2**(es+1))*(N-2);
parameter qsize = (2*bias)+2;
parameter ext = 13;
parameter ss = log2(qsize+ext);

input [N-1:0] IN1, IN2, BIAS;
input MAC_EN, PURGE, RESULT_REQ_PLS, BIAS_EN;
input CLK, RESET;
output [N-1:0] OUT;

//BIAS用のデコード
wire [N-1:0] bias_in;
assign bias_in = BIAS_EN ? BIAS : 0;
wire [N-1:0] xbias = bias_in[N-1] ? -bias_in : bias_in;
wire rc_b;
wire [Bs-1:0] regime_b;
wire [es-1:0] e_b;
wire [N-es-4:0] mant_b;
data_extract #(.N(N), .es(es)) decode_bias(.in(xbias), .rc(rc_b), .regime(regime_b), .exp(e_b), .mant(mant_b));
wire [N-es-3:0] m_b = {1'b1,mant_b};
wire [Bs+1:0] r_b = rc_b ? {2'b0,regime_b} : -regime_b;
wire [Bs+es+1:0] bias_shift = {r_b,e_b} + bias;
wire [2*bias-1+(N-es-2):0] fixed_bias;
DLS #(.N(N-es-2), .S(Bs+es+2), .O(2*bias+(N-es-2))) bias_to_fixed (.a(m_b), .b(bias_shift), .c(fixed_bias));
wire [qsize-1+ext:0] bias_acc_value = bias_in[N-1] ? -{1'b0,{ext{1'b0}},fixed_bias[2*bias-1+(N-es-2):(N-es-2)-1]} : {1'b0,{ext{1'b0}},fixed_bias[2*bias-1+(N-es-2):(N-es-2)-1]};


wire s1 = IN1[N-1];
wire s2 = IN2[N-1];
wire zero_tmp1 = |IN1[N-2:0];
wire zero_tmp2 = |IN2[N-2:0];
wire zero1 = ~(IN1[N-1] | zero_tmp1);
wire zero2 = ~(IN2[N-1] | zero_tmp2);
assign zero = zero1 & zero2;
//Data Extraction
wire rc1, rc2;
wire [Bs-1:0] regime1, regime2;
wire [es-1:0] e1, e2;
wire [N-es-4:0] mant1, mant2;
wire [N-1:0] xin1 = s1 ? -IN1 : IN1;
wire [N-1:0] xin2 = s2 ? -IN2 : IN2;
data_extract #(.N(N), .es(es)) decode1(.in(xin1), .rc(rc1), .regime(regime1), .exp(e1), .mant(mant1));
data_extract #(.N(N), .es(es)) decode2(.in(xin2), .rc(rc2), .regime(regime2), .exp(e2), .mant(mant2));
wire [N-es-3:0] m1 = {zero_tmp1,mant1}, m2 = {zero_tmp2,mant2};

//multiplication
wire mult_s = s1 ^ s2;
wire [2*(N-es-2)-1:0] mult_m = m1 * m2;
wire mult_m_ovf = mult_m[2*(N-es-2)-1];
wire [2*(N-es-2)-1:0] mult_mN_tmp = ~mult_m_ovf ? mult_m << 1'b1 : mult_m;
wire [2*(N-es-2):0] mult_mN = mult_s ? -{1'b0,mult_mN_tmp} : {1'b0,mult_mN_tmp};
wire [Bs+1:0] r1 = rc1 ? {2'b0,regime1} : -regime1;
wire [Bs+1:0] r2 = rc2 ? {2'b0,regime2} : -regime2;
wire [Bs+es+1:0] mult_e;
add_N_Cin #(.N(Bs+es+1)) exp_add({r1,e1}, {r2,e2}, mult_m_ovf, mult_e);
//レジスタの追加
reg [2*(N-es-2):0] mult_value;
reg [Bs+es+1:0] mult_scale;
always @(posedge CLK or negedge RESET)begin
    if(RESET == 1'b0)
        mult_value <= 0;
    else if(PURGE)
        mult_value <= 0;
    else if(MAC_EN)
        mult_value <= mult_mN; 
    else
        mult_value <= 0;
end
always @(posedge CLK or negedge RESET)begin
    if(RESET == 1'b0)
        mult_scale <= 0;
    else if(PURGE)
        mult_scale <= 0;
    else if(MAC_EN)
        mult_scale <= mult_e; 
    else
        mult_scale <= 0;
end

//accumulation
wire [Bs+es+1:0] s_fixed = mult_scale + bias;
wire [2*bias+2*(N-es-2):0] fixed_value;
wire [2*bias+2*(N-es-2):0] mult_value_s = mult_value[2*(N-es-2)] ? {{(2*bias+2*(N-es-2)+1)-(2*(N-es-2)+1){1'b1}},mult_value} : {{(2*bias+2*(N-es-2)+1)-(2*(N-es-2)+1){1'b0}},mult_value};
DLS #(.N(2*bias+2*(N-es-2)+1), .S(Bs+es+2), .O(2*bias+2*(N-es-2)+1))to_fixed (.a(mult_value_s), .b(s_fixed), .c(fixed_value));
wire [qsize-1+ext:0] s_fixed_value = mult_value[2*(N-es-2)] ? {1'b1,{ext{1'b1}},fixed_value[2*bias-1+2*(N-es-2):2*(N-es-2)-1]} : {1'b0,{ext{1'b0}},fixed_value[2*bias-1+2*(N-es-2):2*(N-es-2)-1]}; 
reg [qsize-1+ext:0] quire;

wire [qsize-1+ext:0] quire_add = quire + s_fixed_value;
wire A = s_fixed_value[qsize-1+ext], B = quire[qsize-1+ext], C = quire_add[qsize-1+ext];
//オーバーフローチェック(負のオーバーフローを含む)
wire ovf = ((A^B==0) && (B^C==1)) ? 1'b1 : 1'b0;
wire [qsize-1+ext:0] quire_value;
//オーバーフロー時には値を最大値に近似
assign quire_value = ovf ? ((A==1) ? {1'b1,{qsize-1{1'b0}}} : {1'b0,{qsize-1{1'b1}}}) : quire_add;

//累積時のen信号を1サイクル遅延させるためのレジスタ
reg acc_en;
always @(posedge CLK or negedge RESET)begin
    if(RESET == 1'b0)
        acc_en <= 0;
    else
        acc_en <= MAC_EN;
end

always @ (posedge CLK or negedge RESET) begin
    if(RESET == 1'b0)
        quire <= 0;
    else if(PURGE)
	    quire <= 0;
    else if(BIAS_EN)
        quire <= bias_acc_value;
    else if(acc_en)
        quire <= quire_value;
    else
        quire <= quire;
end

//以下エンコード

wire [qsize-1+ext:0] quire_masked = RESULT_REQ_PLS ? quire : 0;

wire [qsize-1+ext:0] quire_m = quire_masked[qsize-1+ext] ? -quire_masked : quire_masked;

wire [qsize-1+ext:0] tmp_quire_m;
//エンコード前のovfチェック
assign tmp_quire_m = |quire_m[qsize-2+ext:qsize-1] ? {{1+ext{1'b0}},1'b1,{(qsize-2){1'b0}}} : quire_m;

wire [ss-1:0] val_quire;
LOD_N #(.N(qsize+ext)) valid_quire(.in(tmp_quire_m), .out(val_quire));


wire [qsize-1+ext:0] quire_frac_s;
DLS #(.N(qsize+ext), .S(ss), .O(qsize+ext)) get_qfrac (.a(tmp_quire_m), .b(val_quire), .c(quire_frac_s));

wire [es+Bs+1:0] quire_exp = ((qsize+ext-1)-val_quire) - bias;

//指数部からr_oとe_oの抽出
wire [es-1:0] e_o;
wire [Bs:0] r_o;
reg_exp_op #(.es(es), .Bs(Bs), .N(N)) e_r_out(quire_exp, e_o, r_o);

wire [2*N-1+3:0] tmp_o = {{N{~quire_exp[es+Bs+1]}},quire_exp[es+Bs+1],e_o,quire_frac_s[qsize-2+ext:(qsize-2+ext)-((N-1-es)+1)],|quire_frac_s[((qsize-2+ext)-((N-1-es)+1))-1:0]};


wire [3*N-1+3:0] tmp1_o;

DRS #(.N(3*N+3), .S(Bs+1)) drs (.a({tmp_o,{N{1'b0}}}), .b(r_o), .c(tmp1_o));

wire L = tmp1_o[N+4], G = tmp1_o[N+3], R = tmp1_o[N+2], St = |tmp1_o[N+1:0],
     ulp = ((G & (R | St)) | (L & G & ~(R | St)));
wire [N-1:0] rnd_ulp = {{N-1{1'b0}},ulp};

wire [N:0] tmp1_o_rnd_ulp;
add_N #(.N(N)) uut_add_ulp (tmp1_o[2*N-1+3:N+3], rnd_ulp, tmp1_o_rnd_ulp);
wire [N-1:0] tmp1_o_rnd = (r_o < N -1) ? tmp1_o_rnd_ulp[N-1:0] : tmp1_o[2*N-1+3:N+3];

wire [N-2:0] tmp1_oN = quire_masked[qsize-1+ext] ? -tmp1_o_rnd[N-1:1] : tmp1_o_rnd[N-1:1];

wire [N-1:0] OUT_tmp_p;
wire [N-1:0] OUT_tmp_n;
assign OUT_tmp_p = (|tmp1_oN) ? {quire_masked[qsize-1+ext], tmp1_oN} : {quire_masked[qsize-1+ext],{(N-2){1'b0}},1'b1};
assign OUT_tmp_n = (|tmp1_oN) ? {quire_masked[qsize-1+ext], tmp1_oN} : {N{1'b1}};
wire [N-1:0] OUT_tmp;
assign OUT_tmp = quire_masked[qsize-1+ext] ? OUT_tmp_n : OUT_tmp_p;
assign OUT = (quire_masked) ? OUT_tmp : 0;


endmodule

///////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////
module data_extract(in, rc, regime, exp, mant);

function [31:0] log2;
input reg [31:0] value;
	begin
	value = value-1;
	for (log2=0; value>0; log2=log2+1)
        	value = value>>1;
      	end
endfunction

parameter N=8;
parameter Bs=log2(N);
parameter es = 1;
input [N-1:0] in;
output rc;
output [Bs-1:0] regime;
output [es-1:0] exp;
output [N-es-4:0] mant;

wire [N-1:0] xin = in;
assign rc = xin[N-2];

wire [N-1:0] xin_r = rc ? ~xin : xin;

wire [Bs-1:0] k;
LOD_N #(.N(N)) xinst_k(.in({xin_r[N-2:0],rc^1'b0}), .out(k));

assign regime = rc ? k-1 : k;

wire [N-1:0] xin_tmp;
DLS #(.N(N), .S(Bs), .O(N)) ls (.a({xin[N-3:0],2'b0}),.b(k),.c(xin_tmp));

assign exp= xin_tmp[N-1:N-es];
assign mant = xin_tmp[N-es-1:3];

endmodule

module LOD_N (in, out);

  function [31:0] log2;
    input reg [31:0] value;
    begin
      value = value-1;
      for (log2=0; value>0; log2=log2+1)
	value = value>>1;
    end
  endfunction

parameter N = 8;
parameter S = log2(N); 
input [N-1:0] in;
output [S-1:0] out;

wire vld;
LOD #(.N(N)) l1 (in, out, vld);
endmodule


module LOD (in, out, vld);

function [31:0] log2;
input reg [31:0] value;
begin
    value = value-1;
    for (log2=0; value>0; log2=log2+1)
value = value>>1;
end
endfunction

function [31:0] bekizyo;
input reg [31:0] value;
begin
    bekizyo = 1<<value;
end
endfunction


parameter N = 8;
parameter S = log2(N);
parameter Sf = bekizyo(S);

   input [N-1:0] in;
   output [S-1:0] out;
   output vld;

  generate
    if (N == 2)
      begin
        assign vld = |in;
        assign out = ~in[1] & in[0];
      end
    //Nが奇数の場合には右側に0が補われて偶数として再帰
    else if (N & (N-1))
      LOD #(Sf) LOD ({in,{((Sf) - N) {1'b0}}},out,vld);
    else
      begin
        wire [S-2:0] out_l, out_h;
        wire out_vl, out_vh;
        LOD #(N>>1) l(in[(N>>1)-1:0],out_l,out_vl);
        LOD #(N>>1) h(in[N-1:N>>1],out_h,out_vh);
        assign vld = out_vl | out_vh;
        assign out = out_vh ? {1'b0,out_h} : {out_vl,out_l};
      end
  endgenerate
endmodule

module DLS(a,b,c);

parameter N=8;
parameter S=3;
parameter O = 8;
input [N-1:0] a;
input [S-1:0] b;
output [O-1:0] c;

wire [O-1:0] tmp [S-1:0];
assign tmp[0]  = b[0] ? a << 7'd1  : a; 
genvar i;
generate
	for (i=1; i<S; i=i+1)begin:loop_blk
		assign tmp[i] = b[i] ? tmp[i-1] << 2**i : tmp[i-1];
	end
endgenerate
assign c = tmp[S-1];

endmodule

module add_N_Cin (a,b,cin,c);
parameter N=8;
input [N:0] a,b;
input cin;
output [N:0] c;
assign c = a + b + cin;
endmodule

module reg_exp_op (exp_o, e_o, r_o);
parameter es=1;
parameter Bs=3;
parameter N = 8;
input [es+Bs+1:0] exp_o;
output [es-1:0] e_o;
output [Bs:0] r_o;

assign e_o = exp_o[es-1:0];

wire [es+Bs:0] exp_oN_tmp;
conv_2c #(.N(es+Bs)) uut_conv_2c1 (~exp_o[es+Bs:0],exp_oN_tmp);
wire [es+Bs:0] exp_oN = exp_o[es+Bs+1] ? exp_oN_tmp[es+Bs:0] : exp_o[es+Bs:0];

wire [Bs:0] r_o_tmp;
assign r_o_tmp = (~exp_o[es+Bs+1] || |(exp_oN[es-1:0])) ? exp_oN[es+Bs:es] + 1 : exp_oN[es+Bs:es];
assign r_o = (r_o_tmp > N-1) ? N-1 : r_o_tmp;
endmodule

module conv_2c (a,c);
parameter N=10;
input [N:0] a;
output [N:0] c;
assign c = a + 1'b1;
endmodule

module add_N (a,b,c);
parameter N=10;
input [N-1:0] a,b;
output [N:0] c;
assign c = {1'b0,a} + {1'b0,b};
endmodule

module DRS(a,b,c);
        parameter N=8;
        parameter S=3;
        input [N-1:0] a;
        input [S-1:0] b;
        output [N-1:0] c;

wire [N-1:0] tmp [S-1:0];
assign tmp[0]  = b[0] ? a >> 7'd1  : a; 
genvar i;
generate
	for (i=1; i<S; i=i+1)begin:loop_blk
		assign tmp[i] = b[i] ? tmp[i-1] >> 2**i : tmp[i-1];
	end
endgenerate
assign c = tmp[S-1];

endmodule