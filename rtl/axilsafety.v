////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	axilsafety.v
//
// Project:	WB2AXIPSP: bus bridges and other odds and ends
//
// Purpose:	A AXI-Lite bus fault isolator.  This core will isolate any
//		downstream AXI-liite slave faults from the upstream channel.
//	It sits as a bump in the wire between upstream and downstream channels,
//	and so it will consume two clocks--slowing down the slave, but
//	potentially allowing developer to recover in case of a fault.
//
//	This core is configured by a couple parameters, which are key to its
//	functionality.
//
//	OPT_TIMEOUT	Set this to a number to be roughly the longest time
//		period you expect the slave to stall the bus, or likewise
//		the longest time period you expect it to wait for a response.
//		If the slave takes longer for either task, a fault will be
//		detected and reported.
//
//	OPT_SELF_RESET	If set, this will send a reset signal to the downstream
//		core so that you can attempt to restart it without reloading
//		the FPGA.  If set, the o_reset signal will be used to reset
//		the downstream core.
//
//	A second key feature of this core are the outgoing fault indicators,
//	o_write_fault and o_read_fault.  If either signal is ever raised, the
//	slave has (somehow) violated protocol on either the write or the
//	read channels respectively.  Such a violation may (or may not) return an
//	error upstream.  For example, if the slave returns a response
//	following no requests from the master, then no error will be returned
//	up stream (doing so would be a protocol violation), but a fault will
//	still be detected.  Use this line to trigger any internal logic
//	analyzers.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2020, Gisselquist Technology, LLC
//
// This file is part of the WB2AXIP project.
//
// The WB2AXIP project contains free software and gateware, licensed under the
// Apache License, Version 2.0 (the "License").  You may not use this project,
// or this file, except in compliance with the License.  You may obtain a copy
// of the License at
//
//	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
// License for the specific language governing permissions and limitations
// under the License.
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
module axilsafety #(
	parameter	C_AXI_ADDR_WIDTH = 28,
	parameter	C_AXI_DATA_WIDTH = 32,
	parameter	OPT_TIMEOUT = 12,
	parameter	MAX_DEPTH = (OPT_TIMEOUT),
	localparam	AW = C_AXI_ADDR_WIDTH,
	localparam	DW = C_AXI_DATA_WIDTH,
	localparam	LGTIMEOUT = $clog2(OPT_TIMEOUT+1),
	localparam	LGDEPTH   = $clog2(MAX_DEPTH+1),
	parameter [0:0]	OPT_SELF_RESET = 1'b1,
	parameter 	OPT_MIN_RESET = 16,
	parameter [0:0] OPT_WRITES = 1'b1,
	parameter [0:0] OPT_READS  = 1'b1
`ifdef	FORMAL
	, parameter [0:0]	F_OPT_FAULTLESS = 1'b1
`endif
	) (
		output	reg	o_write_fault,
		output	reg	o_read_fault,
		//
		input	wire			S_AXI_ACLK,
		input	wire			S_AXI_ARESETN,
		output	reg			M_AXI_ARESETN,
		//
		input	wire			S_AXI_AWVALID,
		output	reg			S_AXI_AWREADY,
		input	wire	[AW-1:0]	S_AXI_AWADDR,
		input	wire	[2:0]		S_AXI_AWPROT,
		//
		input	wire			S_AXI_WVALID,
		output	reg			S_AXI_WREADY,
		input	wire	[DW-1:0]	S_AXI_WDATA,
		input	wire	[DW/8-1:0]	S_AXI_WSTRB,
		//
		output	reg			S_AXI_BVALID,
		input	wire			S_AXI_BREADY,
		output	reg	[1:0]		S_AXI_BRESP,
		//
		input	wire			S_AXI_ARVALID,
		output	reg			S_AXI_ARREADY,
		input	wire	[AW-1:0]	S_AXI_ARADDR,
		input	wire	[2:0]		S_AXI_ARPROT,
		//
		output	reg			S_AXI_RVALID,
		input	wire			S_AXI_RREADY,
		output	reg	[DW-1:0]	S_AXI_RDATA,
		output	reg	[1:0]		S_AXI_RRESP,
		//
		//
		//
		output	reg			M_AXI_AWVALID,
		input	wire			M_AXI_AWREADY,
		output	reg	[AW-1:0]	M_AXI_AWADDR,
		output	reg	[2:0]		M_AXI_AWPROT,
		//
		output	reg			M_AXI_WVALID,
		input	wire			M_AXI_WREADY,
		output	reg	[DW-1:0]	M_AXI_WDATA,
		output	reg	[DW/8-1:0]	M_AXI_WSTRB,
		//
		input	wire			M_AXI_BVALID,
		output	wire			M_AXI_BREADY,
		input	wire	[1:0]		M_AXI_BRESP,
		//
		output	reg			M_AXI_ARVALID,
		input	wire			M_AXI_ARREADY,
		output	reg	[AW-1:0]	M_AXI_ARADDR,
		output	reg	[2:0]		M_AXI_ARPROT,
		//
		input	wire			M_AXI_RVALID,
		output	reg			M_AXI_RREADY,
		input	wire	[DW-1:0]	M_AXI_RDATA,
		input	wire	[1:0]		M_AXI_RRESP
	);
	//
	localparam	OPT_LOWPOWER = 1'b0;

	reg	[LGDEPTH-1:0]	aw_count, w_count, r_count;
	reg			aw_zero, w_zero, r_zero,
				aw_full, w_full, r_full,
				aw_w_greater, w_aw_greater;
	reg	[LGDEPTH-1:0]	downstream_aw_count, downstream_w_count, downstream_r_count;
	reg			downstream_aw_zero, downstream_w_zero, downstream_r_zero;
				// downstream_aw_w_greater, downstream_w_aw_greater;

	////////////////////////////////////////////////////////////////////////
	//
	// Start with a skid buffer on all incoming signals
	//
	////////////////////////////////////////////////////////////////////////
	//
	//
	wire			awskd_valid;
	wire	[2:0]		awskd_prot;
	wire	[AW-1:0]	awskd_addr;
	reg			awskd_ready;

	skidbuffer #(.DW(AW+3)
`ifdef	FORMAL
		, .OPT_PASSTHROUGH(1'b1)
`endif
	) awskd(S_AXI_ACLK, !S_AXI_ARESETN,
		S_AXI_AWVALID, S_AXI_AWREADY, { S_AXI_AWPROT, S_AXI_AWADDR },
		awskd_valid, awskd_ready, { awskd_prot, awskd_addr});

	always @(*)
	if (!M_AXI_ARESETN || o_write_fault)
		awskd_ready = (w_aw_greater)
			||((aw_count == 0)&&(!S_AXI_BVALID || S_AXI_BREADY));
	else
		awskd_ready = (!M_AXI_AWVALID || M_AXI_AWREADY)&& (!aw_full);

	initial	M_AXI_AWVALID = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN)
		M_AXI_AWVALID <= 1'b0;
	else if (!M_AXI_AWVALID || M_AXI_AWREADY)
		M_AXI_AWVALID <= awskd_valid && awskd_ready && !o_write_fault;

	always @(posedge S_AXI_ACLK)
	if (OPT_LOWPOWER && (!M_AXI_ARESETN || o_write_fault))
	begin
		M_AXI_AWADDR <= 0;
		M_AXI_AWPROT <= 0;
	end else if (!M_AXI_AWVALID || M_AXI_AWREADY)
	begin
		M_AXI_AWADDR <= awskd_addr;
		M_AXI_AWPROT <= awskd_prot;
	end

	wire			wskd_valid;
	wire	[DW-1:0]	wskd_data;
	wire	[DW/8-1:0]	wskd_strb;
	reg			wskd_ready;
	skidbuffer #(.DW(DW+DW/8)
`ifdef	FORMAL
		, .OPT_PASSTHROUGH(1'b1)
`endif
	) wskd(S_AXI_ACLK, !S_AXI_ARESETN,
		S_AXI_WVALID, S_AXI_WREADY, { S_AXI_WDATA, S_AXI_WSTRB },
		wskd_valid, wskd_ready, { wskd_data, wskd_strb});

	always @(*)
	if (!M_AXI_ARESETN || o_write_fault)
		wskd_ready = (aw_w_greater)
			|| ((w_zero)&&(!S_AXI_BVALID || S_AXI_BREADY));
	else
		wskd_ready = M_AXI_ARESETN && (!M_AXI_WVALID || M_AXI_WREADY)
			&& (!w_full);

	initial	M_AXI_WVALID = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN)
		M_AXI_WVALID <= 1'b0;
	else if (!M_AXI_WVALID || M_AXI_WREADY)
		M_AXI_WVALID <= wskd_valid && wskd_ready && !o_write_fault;

	always @(posedge S_AXI_ACLK)
	if (OPT_LOWPOWER && (!M_AXI_ARESETN || o_write_fault))
	begin
		M_AXI_WDATA <= 0;
		M_AXI_WSTRB <= 0;
	end else if (!M_AXI_WVALID || M_AXI_WREADY)
	begin
		M_AXI_WDATA <= wskd_data;
		M_AXI_WSTRB <= (o_write_fault) ? 0 : wskd_strb;
	end

	wire		bskd_valid;
	wire	[1:0]	bskd_resp;
	reg		bskd_ready;

`ifdef	FORMAL
	assign	bskd_valid = M_AXI_BVALID;
	assign	M_AXI_BREADY= bskd_ready;
	assign	bskd_resp  = M_AXI_BRESP;
`else
	skidbuffer #(.DW(2)
	) bskd(S_AXI_ACLK, !S_AXI_ARESETN || !M_AXI_ARESETN,
		M_AXI_BVALID, M_AXI_BREADY, M_AXI_BRESP,
		bskd_valid, bskd_ready,  bskd_resp);
`endif

	always @(*)
	if (o_write_fault)
		bskd_ready = 1'b1;
	else
		bskd_ready = (!S_AXI_BVALID || S_AXI_BREADY);

	initial	S_AXI_BVALID = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		S_AXI_BVALID <= 1'b0;
	else if (!S_AXI_BVALID || S_AXI_BREADY)
	begin
		if (o_write_fault || !M_AXI_ARESETN)
			S_AXI_BVALID <= (!S_AXI_BVALID&&(!aw_zero)&&(!w_zero));
		else
			S_AXI_BVALID <= (!downstream_aw_zero)
				&&(!downstream_w_zero)&&(bskd_valid);
	end

	reg		last_bvalid;
	reg	[1:0]	last_bdata;
	reg		last_bchanged;

	initial	last_bvalid = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (!M_AXI_ARESETN || o_write_fault)
		last_bvalid <= 1'b0;
	else
		last_bvalid <= (M_AXI_BVALID && !M_AXI_BREADY);

	always @(posedge S_AXI_ACLK)
	if (M_AXI_BVALID)
		last_bdata <= M_AXI_BRESP;

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN || o_write_fault)
		last_bchanged <= 1'b0;
	else
		last_bchanged <= (last_bvalid && (!M_AXI_BVALID
					|| last_bdata != M_AXI_BRESP));
		

	initial	S_AXI_BRESP = 2'b00;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_BVALID || S_AXI_BREADY)
	begin
		if (o_write_fault)
			S_AXI_BRESP <= 2'b10;
		else if (bskd_resp == 2'b01)
			S_AXI_BRESP <= 2'b10;
		else
			S_AXI_BRESP <= bskd_resp;
	end

	wire	arskd_valid;
	wire	[2:0]	arskd_prot;
	wire	[AW-1:0]	arskd_addr;
	reg			arskd_ready;

	skidbuffer #(.DW(AW+3)
`ifdef	FORMAL
		, .OPT_PASSTHROUGH(1'b1)
`endif
	) arskd(S_AXI_ACLK, !S_AXI_ARESETN,
		S_AXI_ARVALID, S_AXI_ARREADY, { S_AXI_ARPROT, S_AXI_ARADDR },
		arskd_valid, arskd_ready,  { arskd_prot, arskd_addr });

	always @(*)
	if (!M_AXI_ARESETN || o_read_fault)
		arskd_ready =((r_count == 0)&&(!S_AXI_RVALID || S_AXI_RREADY));
	else
		arskd_ready = (!M_AXI_ARVALID || M_AXI_ARREADY) && (!r_full);

	initial	M_AXI_ARVALID = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN)
		M_AXI_ARVALID <= 1'b0;
	else if (!M_AXI_ARVALID || M_AXI_ARREADY)
		M_AXI_ARVALID <= arskd_valid && arskd_ready && !o_read_fault;

	always @(posedge S_AXI_ACLK)
	if (OPT_LOWPOWER && (!M_AXI_ARESETN || o_read_fault))
	begin
		M_AXI_ARADDR <= 0;
		M_AXI_ARPROT <= 0;
	end else if (!M_AXI_ARVALID || M_AXI_ARREADY)
	begin
		M_AXI_ARADDR <= arskd_addr;
		M_AXI_ARPROT <= arskd_prot;
	end

	reg		last_rvalid;
	reg [DW+1:0]	last_rdata;
	reg		last_rchanged;

	initial	last_rvalid = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN || o_read_fault)
		last_rvalid <= 1'b0;
	else
		last_rvalid <= (M_AXI_RVALID && !M_AXI_RREADY);

	always @(posedge S_AXI_ACLK)
	if (M_AXI_RVALID)
		last_rdata <= { M_AXI_RRESP, M_AXI_RDATA };

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN || o_read_fault)
		last_rchanged <= 1'b0;
	else
		last_rchanged <= (last_rvalid && (!M_AXI_RVALID
			|| last_rdata != { M_AXI_RRESP, M_AXI_RDATA }));
		

	wire	rskd_valid;
	wire	[1:0]	rskd_resp;
	wire	[DW-1:0]	rskd_data;
	reg			rskd_ready;

`ifdef	FORMAL
	assign	rskd_valid = M_AXI_RVALID;
	assign	M_AXI_RREADY = rskd_ready;
	assign	{ rskd_resp, rskd_data } = { M_AXI_RRESP, M_AXI_RDATA };
`else
	skidbuffer #(.DW(DW+2)
	) rskd(S_AXI_ACLK, !S_AXI_ARESETN || !M_AXI_ARESETN,
		M_AXI_RVALID, M_AXI_RREADY, { M_AXI_RRESP, M_AXI_RDATA },
		rskd_valid, rskd_ready,  { rskd_resp, rskd_data });
`endif

	always @(*)
	if (o_read_fault)
		rskd_ready = 1;
	else
		rskd_ready = (!S_AXI_RVALID || S_AXI_RREADY);

	initial	S_AXI_RVALID = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		S_AXI_RVALID <= 1'b0;
	else if (!S_AXI_RVALID || S_AXI_RREADY)
	begin
		if (o_read_fault || !M_AXI_ARESETN)
			S_AXI_RVALID <= (!S_AXI_RVALID && !r_zero)
					|| (arskd_valid && arskd_ready);
		else
			S_AXI_RVALID <= (!downstream_r_zero)&&(rskd_valid);
	end

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_RVALID || S_AXI_RREADY)
	begin
		if (o_read_fault || !M_AXI_ARESETN)
			S_AXI_RDATA <= 0;
		else
			S_AXI_RDATA <= rskd_data;

		S_AXI_RRESP <= 2'b00;
		if (o_read_fault || rskd_resp == 2'b01)
			S_AXI_RRESP <= 2'b10;
		else if (downstream_r_count > 0)
			S_AXI_RRESP <= rskd_resp;
		else if (rskd_valid)
			S_AXI_RRESP <= 2'b10;
	end

	initial	aw_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		aw_count <= 0;
	else case({(awskd_valid && awskd_ready), S_AXI_BVALID && S_AXI_BREADY})
	2'b10: aw_count <= aw_count + 1;
	2'b01: aw_count <= aw_count - 1;
	default: begin end
	endcase

	always @(*)
		aw_zero = (aw_count == 0);

	always @(*)
		aw_full = (&aw_count);

	initial	w_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		w_count <= 0;
	else case({(wskd_valid && wskd_ready), S_AXI_BVALID && S_AXI_BREADY})
	2'b10: w_count <= w_count + 1;
	2'b01: w_count <= w_count - 1;
	default: begin end
	endcase

	always @(*)
		w_zero = (w_count == 0);

	always @(*)
		w_full = (&w_count);

	always @(*)
		aw_w_greater = (aw_count > w_count);

	always @(*)
		w_aw_greater = (aw_count < w_count);

	initial	r_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		r_count <= 0;
	else case({(arskd_valid && arskd_ready), S_AXI_RVALID && S_AXI_RREADY})
	2'b10: r_count <= r_count + 1;
	2'b01: r_count <= r_count - 1;
	default: begin end
	endcase

	always @(*)
		r_zero = (r_count == 0);

	always @(*)
		r_full = (&r_count);

	initial	downstream_aw_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN || o_write_fault)
		downstream_aw_count <= 0;
	else case({(M_AXI_AWVALID && M_AXI_AWREADY), M_AXI_BVALID && M_AXI_BREADY})
	2'b10: downstream_aw_count <= downstream_aw_count + 1;
	2'b01: downstream_aw_count <= downstream_aw_count - 1;
	default: begin end
	endcase

	always @(*)
		downstream_aw_zero = (downstream_aw_count == 0);

	initial	downstream_w_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN || o_write_fault)
		downstream_w_count <= 0;
	else case({(M_AXI_WVALID && M_AXI_WREADY), M_AXI_BVALID && M_AXI_BREADY})
	2'b10: downstream_w_count <= downstream_w_count + 1;
	2'b01: downstream_w_count <= downstream_w_count - 1;
	default: begin end
	endcase

	always @(*)
		downstream_w_zero = (downstream_w_count == 0);

	initial	downstream_r_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || o_read_fault || !M_AXI_ARESETN)
		downstream_r_count <= 0;
	else case({M_AXI_ARVALID && M_AXI_ARREADY, M_AXI_RVALID && M_AXI_RREADY})
	2'b10: downstream_r_count <= downstream_r_count + 1;
	2'b01: downstream_r_count <= downstream_r_count - 1;
	default: begin end
	endcase

	always @(*)
		downstream_r_zero = (downstream_r_count == 0);

	////////////////////////////////////////////////////////////////////////
	//
	// Timeout checking
	//
	////////////////////////////////////////////////////////////////////////
	//
	//
	reg [LGTIMEOUT-1:0]	aw_stall_counter, w_stall_counter,
				r_stall_counter, w_ack_timer, r_ack_timer;
	reg 	aw_stall_limit, w_stall_limit, r_stall_limit, w_ack_limit,
				r_ack_limit;

	initial	aw_stall_counter = 0;
	initial	aw_stall_limit   = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || o_write_fault || !M_AXI_ARESETN)
	begin
		aw_stall_counter <= 0;
		aw_stall_limit   <= 0;
	end else if (!M_AXI_AWVALID || M_AXI_AWREADY || M_AXI_BVALID)
	begin
		aw_stall_counter <= 0;
		aw_stall_limit   <= 0;
	end else if (aw_w_greater && !M_AXI_WVALID)
	begin
		aw_stall_counter <= 0;
		aw_stall_limit   <= 0;
	end else // if (!S_AXI_BVALID || S_AXI_BREADY)
	begin
		aw_stall_counter <= aw_stall_counter + 1;
		aw_stall_limit   <= (aw_stall_counter+1 >= OPT_TIMEOUT);
	end

	initial	w_stall_counter = 0;
	initial	w_stall_limit   = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN || o_write_fault)
	begin
		w_stall_counter <= 0;
		w_stall_limit   <= 0;
	end else if (!M_AXI_WVALID || M_AXI_WREADY || M_AXI_BVALID)
	begin
		w_stall_counter <= 0;
		w_stall_limit   <= 0;
	end else if (w_aw_greater && !M_AXI_AWVALID)
	begin
		w_stall_counter <= 0;
		w_stall_limit   <= 0;
	end else // if (!M_AXI_BVALID || M_AXI_BREADY)
	begin
		w_stall_counter <= w_stall_counter + 1;
		w_stall_limit   <= (w_stall_counter + 1 >= OPT_TIMEOUT);
	end

	initial w_ack_timer = 0;
	initial	w_ack_limit = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN || o_write_fault)
	begin
		w_ack_timer <= 0;
		w_ack_limit <= 0;
	end else if (M_AXI_BVALID || downstream_aw_zero || downstream_w_zero)
	begin
		w_ack_timer <= 0;
		w_ack_limit <= 0;
	end else
	begin
		w_ack_timer <= w_ack_timer + 1;
		w_ack_limit <= (w_ack_timer + 1 >= OPT_TIMEOUT);
	end

	initial r_stall_counter = 0;
	initial	r_stall_limit   = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN || o_read_fault)
	begin
		r_stall_counter <= 0;
		r_stall_limit   <= 0;
	end else if (!M_AXI_ARVALID || M_AXI_ARREADY || M_AXI_RVALID)
	begin
		r_stall_counter <= 0;
		r_stall_limit   <= 0;
	end else begin
		r_stall_counter <= r_stall_counter + 1;
		r_stall_limit   <= (r_stall_counter + 1 >= OPT_TIMEOUT);
	end

	initial r_ack_timer = 0;
	initial	r_ack_limit = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || !M_AXI_ARESETN || o_read_fault)
	begin
		r_ack_timer <= 0;
		r_ack_limit <= 0;
	end else if (M_AXI_RVALID || downstream_r_zero)
	begin
		r_ack_timer <= 0;
		r_ack_limit <= 0;
	end else begin
		r_ack_timer <= r_ack_timer + 1;
		r_ack_limit <= (r_ack_timer + 1 >= OPT_TIMEOUT);
	end

	////////////////////////////////////////////////////////////////////////
	//
	// Fault detection
	//
	////////////////////////////////////////////////////////////////////////
	//
	//
	initial	o_write_fault =1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		o_write_fault <= 1'b0;
	else if (o_write_fault && OPT_SELF_RESET)
	begin
		if (!M_AXI_ARESETN && aw_zero && w_zero)
			o_write_fault <= 1'b0;
	end else begin
		if ((downstream_aw_zero || downstream_w_zero)&&(bskd_valid))
			o_write_fault <= 1'b1;
		if (bskd_valid && bskd_resp == 2'b01)
			o_write_fault <= 1'b1;
		if (aw_stall_limit || w_stall_limit || w_ack_limit)
			o_write_fault <= 1'b1;
		if (last_bchanged)
			o_write_fault <= 1'b1;
	end

	initial	o_read_fault =1'b0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		o_read_fault <= 1'b0;
	else if (o_read_fault && OPT_SELF_RESET)
	begin
		if (!M_AXI_ARESETN && r_zero)
			o_read_fault <= 1'b0;
	end else begin
		if (downstream_r_zero && rskd_valid)
			o_read_fault <= 1'b1;
		if (rskd_valid && rskd_resp == 2'b01)
			o_read_fault <= 1'b1;
		if (r_stall_limit || r_ack_limit)
			o_read_fault <= 1'b1;
		if (last_rchanged)
			o_read_fault <= 1'b1;
	end

	generate if (OPT_SELF_RESET)
	begin : SELF_RESET_GENERATION
		reg		min_reset;

		if (OPT_MIN_RESET > 1)
		begin : MIN_RESET

			reg	[$clog2(OPT_MIN_RESET+1):0]	reset_counter;

			initial reset_counter = OPT_MIN_RESET-1;
			initial	min_reset = 1'b0;
			always @(posedge S_AXI_ARESETN)
			if (M_AXI_ARESETN)
			begin
				reset_counter <= OPT_MIN_RESET-1;
				min_reset <= 1'b0;
			end else if (!M_AXI_ARESETN)
			begin
				if (reset_counter > 0)
					reset_counter <= reset_counter-1;
				min_reset <= (reset_counter <= 1);	
			end

`ifdef	FORMAL
			always @(*)
				assert(reset_counter < OPT_MIN_RESET);
			always @(*)
				assert(min_reset == (reset_counter == 0));
`endif
		end else begin

			always @(*)
				min_reset = 1'b1;

		end
				
		
		initial	M_AXI_ARESETN = 1'b0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
			M_AXI_ARESETN <= 1'b0;
		else if (o_write_fault || o_read_fault)
			M_AXI_ARESETN <= 1'b0;
		else if (aw_zero && w_zero && r_zero && min_reset
			&& !awskd_valid && !wskd_valid && !arskd_valid)
			M_AXI_ARESETN <= 1'b1;

	end else begin : SAME_RESET

		always @(*)
			M_AXI_ARESETN = S_AXI_ARESETN;

	end endgenerate

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
//
// Formal property section
//
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	//
	// The following proof comes in several parts.
	//
	// 1. PROVE that the upstream properties will hold independent of
	//	what the downstream slave ever does.
	//
	// 2. PROVE that if the downstream slave follows protocol, then
	//	neither o_write_fault nor o_read_fault will never get raised.
	//
	// We then repeat these proofs again with both OPT_SELF_RESET set and
	// clear.  Which of the four proofs is accomplished is dependent upon
	// parameters set by the formal engine. 
	//
	//
	localparam	DOWNSTREAM_ACK_DELAY = OPT_TIMEOUT/2-1;
	localparam	UPSTREAM_ACK_DELAY = OPT_TIMEOUT + 3;
	wire	[LGDEPTH:0]	faxils_awr_outstanding, faxils_wr_outstanding,
				faxils_rd_outstanding;

	reg	f_past_valid;
	initial	f_past_valid = 0;
	always @(posedge S_AXI_ACLK)
		f_past_valid <= 1;

	////////////////////////////////////////////////////////////////////////
	//
	// Upstream master Bus properties
	//
	always @(*)
	if (!f_past_valid)
	begin
		assume(!S_AXI_ARESETN);
		assert(!M_AXI_ARESETN);
	end

	faxil_slave #(
		.C_AXI_DATA_WIDTH(C_AXI_DATA_WIDTH),
		.C_AXI_ADDR_WIDTH(C_AXI_ADDR_WIDTH),
		.F_OPT_ASSUME_RESET(1'b1),
		.F_OPT_NO_RESET((OPT_MIN_RESET == 0) ? 1:0),
		// .F_MAX_ACK_DELAY(UPSTREAM_ACK_DELAY),
		.F_AXI_MAXWAIT((F_OPT_FAULTLESS) ? (2*OPT_TIMEOUT+2) : 0),
		.F_AXI_MAXRSTALL(3),
		.F_AXI_MAXDELAY(OPT_TIMEOUT+OPT_TIMEOUT+5),
		.F_LGDEPTH(LGDEPTH+1)
	) axils (
		.i_clk(S_AXI_ACLK),
		.i_axi_reset_n(S_AXI_ARESETN),
		//
		.i_axi_awvalid(S_AXI_AWVALID),
		.i_axi_awready(S_AXI_AWREADY),
		.i_axi_awaddr( S_AXI_AWADDR),
		.i_axi_awprot( S_AXI_AWPROT),
		.i_axi_awcache(4'h0),
		//
		.i_axi_wvalid(S_AXI_WVALID),
		.i_axi_wready(S_AXI_WREADY),
		.i_axi_wdata( S_AXI_WDATA),
		.i_axi_wstrb( S_AXI_WSTRB),
		//
		.i_axi_bvalid(S_AXI_BVALID),
		.i_axi_bready(S_AXI_BREADY),
		.i_axi_bresp( S_AXI_BRESP),
		//
		.i_axi_arvalid(S_AXI_ARVALID),
		.i_axi_arready(S_AXI_ARREADY),
		.i_axi_araddr( S_AXI_ARADDR),
		.i_axi_arprot( S_AXI_ARPROT),
		.i_axi_arcache(4'h0),
		//
		.i_axi_rvalid(S_AXI_RVALID),
		.i_axi_rready(S_AXI_RREADY),
		.i_axi_rdata( S_AXI_RDATA),
		.i_axi_rresp( S_AXI_RRESP),
		//
		.f_axi_awr_outstanding(faxils_awr_outstanding),
		.f_axi_wr_outstanding(faxils_wr_outstanding),
		.f_axi_rd_outstanding(faxils_rd_outstanding)
	);

	always @(*)
	begin
		assert(aw_zero == (aw_count  == 0));
		assert(w_zero  == (w_count   == 0));
		assert(r_zero  == (r_count   == 0));
		//
		assert(aw_full == (&aw_count));
		assert(w_full  == (&w_count));
		assert(r_full  == (&r_count));
		//
		if (M_AXI_ARESETN && !o_write_fault)
		begin
			assert(downstream_aw_count + (M_AXI_AWVALID ? 1:0)
					+ (S_AXI_BVALID ? 1:0) == aw_count);
			assert(downstream_w_count + (M_AXI_WVALID ? 1:0)
					+ (S_AXI_BVALID ? 1:0) ==  w_count);
		end

		if (M_AXI_ARESETN && !o_read_fault)
			assert(downstream_r_count + (M_AXI_ARVALID ? 1:0)
					+ (S_AXI_RVALID ? 1:0) ==  r_count);
		//
		assert(aw_count == faxils_awr_outstanding);
		assert(w_count  == faxils_wr_outstanding);
		assert(r_count  == faxils_rd_outstanding);
	end

	always @(*)
	if (!OPT_WRITES)
	begin
		assume(!S_AXI_AWVALID);
		assume(!S_AXI_WVALID);
		assert(aw_count == 0);
		assert(w_count == 0);
		assert(!M_AXI_AWVALID);
		assert(!M_AXI_WVALID);
	end

	always @(*)
	if (!OPT_READS)
	begin
		assume(!S_AXI_ARVALID);
		assert(r_count == 0);
		assert(!S_AXI_RVALID);
		assert(!M_AXI_ARVALID);
	end

	generate if (F_OPT_FAULTLESS)
	begin : ASSUME_FAULTLESS
		////////////////////////////////////////////////////////////////
		//
		// Assume the downstream core is protocol compliant, and
		// prove that o_fault stays low.
		//
		wire	[LGDEPTH:0]	faxilm_awr_outstanding,
					faxilm_wr_outstanding,
					faxilm_rd_outstanding;

		faxil_master #(
			.C_AXI_DATA_WIDTH(C_AXI_DATA_WIDTH),
			.C_AXI_ADDR_WIDTH(C_AXI_ADDR_WIDTH),
			.F_OPT_NO_RESET((OPT_MIN_RESET == 0) ? 1:0),
			// .F_MAX_ACK_DELAY(UPSTREAM_ACK_DELAY),
			.F_AXI_MAXWAIT(OPT_TIMEOUT),
			.F_AXI_MAXRSTALL(4),
			.F_AXI_MAXDELAY(OPT_TIMEOUT),
			.F_LGDEPTH(LGDEPTH+1)
		) axilm (
			.i_clk(S_AXI_ACLK),
			.i_axi_reset_n(M_AXI_ARESETN && S_AXI_ARESETN),
			//
			.i_axi_awvalid(M_AXI_AWVALID),
			.i_axi_awready(M_AXI_AWREADY),
			.i_axi_awaddr( M_AXI_AWADDR),
			.i_axi_awprot( M_AXI_AWPROT),
			.i_axi_awcache(4'h0),
			//
			.i_axi_wvalid(M_AXI_WVALID),
			.i_axi_wready(M_AXI_WREADY),
			.i_axi_wdata( M_AXI_WDATA),
			.i_axi_wstrb( M_AXI_WSTRB),
			//
			.i_axi_bvalid(M_AXI_BVALID),
			.i_axi_bready(M_AXI_BREADY),
			.i_axi_bresp( M_AXI_BRESP),
			//
			.i_axi_arvalid(M_AXI_ARVALID),
			.i_axi_arready(M_AXI_ARREADY),
			.i_axi_araddr( M_AXI_ARADDR),
			.i_axi_arprot( M_AXI_ARPROT),
			.i_axi_arcache(4'h0),
			//
			.i_axi_rvalid(M_AXI_RVALID),
			.i_axi_rready(M_AXI_RREADY),
			.i_axi_rdata( M_AXI_RDATA),
			.i_axi_rresp( M_AXI_RRESP),
			//
			.f_axi_awr_outstanding(faxilm_awr_outstanding),
			.f_axi_wr_outstanding(faxilm_wr_outstanding),
			.f_axi_rd_outstanding(faxilm_rd_outstanding)
		);

		//
		// Here's the big proof
		always @(*)
			assert(!o_write_fault);
		always @(*)
			assert(!o_read_fault);

		////////////////////////////////////////////////////////////////
		//
		// The following properties are necessary for passing induction
		//
		always @(*)
		begin
			assert(!aw_stall_limit);
			assert(!w_stall_limit);
			assert(!w_ack_limit);

			assert(!r_stall_limit);
			assert(!r_ack_limit);

			if (M_AXI_ARESETN)
			begin
			assert(downstream_aw_count == faxilm_awr_outstanding);
			assert(downstream_w_count  == faxilm_wr_outstanding);
			assert(downstream_r_count  == faxilm_rd_outstanding);
			end
		end

		if (OPT_SELF_RESET)
		begin
			always @(posedge S_AXI_ARESETN)
			if (f_past_valid)
				assert(M_AXI_ARESETN == $past(S_AXI_ARESETN));
		end

`ifdef	VERIFIC
		wire	[LGDEPTH:0]	f_axi_arstall;
		wire	[LGDEPTH:0]	f_axi_awstall;
		wire	[LGDEPTH:0]	f_axi_wstall;

		assign	f_axi_awstall = axilm.CHECK_STALL_COUNT.f_axi_awstall;
		assign	f_axi_wstall  = axilm.CHECK_STALL_COUNT.f_axi_wstall;
		assign	f_axi_arstall = axilm.CHECK_STALL_COUNT.f_axi_arstall;

		always @(*)
		if (M_AXI_ARESETN && S_AXI_ARESETN && !o_write_fault)
			assert(f_axi_awstall == aw_stall_counter);

		always @(*)
		if (M_AXI_ARESETN && S_AXI_ARESETN && !o_write_fault)
			assert(f_axi_wstall == w_stall_counter);

		always @(*)
		if (M_AXI_ARESETN && S_AXI_ARESETN && !o_read_fault)
			assert(f_axi_arstall == r_stall_counter);
`endif
	end else begin : WILD_DOWNSTREAM
		// Just so we pass the skid buffer's assumptions ...

		always @(posedge S_AXI_ACLK)
		if (f_past_valid && $past(M_AXI_ARESETN && M_AXI_BVALID && !M_AXI_BREADY))
		begin
			assume(M_AXI_BVALID);
			assume($stable(M_AXI_BRESP));
		end

		always @(posedge S_AXI_ACLK)
		if (f_past_valid && $past(M_AXI_ARESETN && M_AXI_RVALID && !M_AXI_RREADY))
		begin
			assume(M_AXI_RVALID);
			assume($stable(M_AXI_RDATA));
			assume($stable(M_AXI_RRESP));
		end

		////////////////////////////////////////////////////////////////
		//
		// cover() checks, checks that only make sense if faults are
		// possible
		//

		if (OPT_SELF_RESET)
		begin
			////////////////////////////////////////////////////////
			//
			// Prove that we can actually reset the downstream
			// bus/core as desired
			//
			reg	write_faulted, read_faulted, faulted;

			initial	write_faulted = 0;
			always @(posedge S_AXI_ACLK)
			if (!S_AXI_ARESETN)
				write_faulted <= 0;
			else if (o_write_fault)
				write_faulted <= 1;


			initial	faulted = 0;
			always @(posedge S_AXI_ACLK)
			if (!S_AXI_ARESETN)
				read_faulted <= 0;
			else if (o_read_fault)
				read_faulted <= 1;

			always @(*)
				faulted = (write_faulted || read_faulted);

			always @(posedge S_AXI_ACLK)
				cover(write_faulted && $rose(M_AXI_ARESETN));

			always @(posedge S_AXI_ACLK)
				cover(read_faulted && $rose(M_AXI_ARESETN));

			always @(posedge S_AXI_ACLK)
				cover(faulted && M_AXI_ARESETN && S_AXI_BVALID);

			always @(posedge S_AXI_ACLK)
				cover(faulted && M_AXI_ARESETN && S_AXI_RVALID);

		end

	end endgenerate

`endif
endmodule
