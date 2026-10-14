// UVM testbench for FIFO.sv (the DUT and fifo_if are defined in FIFO.sv).
// Compile order: FIFO.sv first, then this file. Top module: tb. Test: fifo_test.
// NOTE: Questa Starter FPGA Edition has no license for randomize(), so the stimulus
// uses $urandom_range by default. Compile with +define+USE_RANDOMIZE to use randomize().

`include "uvm_macros.svh"   // UVM macros (`uvm_info, `uvm_component_utils, etc.)
import uvm_pkg::*;          // Import all UVM classes

///////////////////////////////////////////////////

// Define the transaction class to represent FIFO transactions.
class transaction extends uvm_sequence_item;
  
  rand bit oper;          // Randomized bit for operation control (1 for write, 0 for read)
  rand bit [7:0] data_in; // Randomized 8-bit data to be written
  bit rd, wr;             // Read and write control bits observed by the monitor
  bit full, empty;        // Flags indicating the full and empty status of the FIFO
  bit [7:0] data_out;     // 8-bit data output observed by the monitor

  // Constraint to keep the write data in the range 1 to 255 (only used with randomize())
  constraint c_data { data_in inside {[1:255]}; }

  `uvm_object_utils(transaction)  // Register the class with the UVM factory

  // Constructor for the transaction class
  function new(string name = "transaction");
    super.new(name);  // Call the parent (uvm_sequence_item) constructor
  endfunction

  // Function to convert the transaction into a printable string
  function string convert2string();
    return $sformatf("wr:%0d rd:%0d din:%0d dout:%0d full:%0d empty:%0d",
                     wr, rd, data_in, data_out, full, empty);
  endfunction
  
endclass

///////////////////////////////////////////////////

// Random sequence generates a stream of random read/write transactions (replaces the generator).
class fifo_rand_seq extends uvm_sequence #(transaction);
  
  `uvm_object_utils(fifo_rand_seq)  // Register the class with the UVM factory
  int unsigned num_txn = 50;        // Number of transactions to generate

  // Constructor for the sequence class
  function new(string name = "fifo_rand_seq");
    super.new(name);
  endfunction

  // Task that creates and sends the transactions to the driver
  task body();
    transaction tr;                 // Transaction handle used for each item
    repeat (num_txn) begin          // Generate transactions 'num_txn' number of times
      tr = transaction::type_id::create("tr");  // Create a new transaction using the factory
      start_item(tr);               // Wait for the driver to be ready for an item
`ifdef USE_RANDOMIZE
      if (!tr.randomize()) `uvm_error("SEQ", "Randomization failed")  // Randomize the transaction
`else
      tr.oper    = $urandom_range(0, 1);    // 50% write, 50% read
      tr.data_in = $urandom_range(1, 255);  // Random data value
`endif
      finish_item(tr);              // Send the transaction to the driver and wait until it is done
    end
  endtask
  
endclass

///////////////////////////////////////////////////

// Fill/drain sequence overfills and then over-drains the FIFO to hit the full and empty corner cases.
class fifo_fill_drain_seq extends uvm_sequence #(transaction);
  
  `uvm_object_utils(fifo_fill_drain_seq)  // Register the class with the UVM factory
  int unsigned num_writes = 20;  // Number of writes (DEPTH is 16, so the last few hit "full")
  int unsigned num_reads  = 20;  // Number of reads (more than stored, so the last few hit "empty")

  // Constructor for the sequence class
  function new(string name = "fifo_fill_drain_seq");
    super.new(name);
  endfunction

  // Task that sends all the writes first and then all the reads
  task body();
    transaction tr;                 // Transaction handle used for each item
    
    repeat (num_writes) begin       // Phase 1: write repeatedly
      tr = transaction::type_id::create("tr");
      start_item(tr);
      tr.oper    = 1'b1;                    // Write operation
      tr.data_in = $urandom_range(1, 255);  // Random data value
      finish_item(tr);
    end
    
    repeat (num_reads) begin        // Phase 2: read repeatedly
      tr = transaction::type_id::create("tr");
      start_item(tr);
      tr.oper = 1'b0;                       // Read operation
      finish_item(tr);
    end
  endtask
  
endclass

////////////////////////////////////////////

// Driver class sends transactions to the DUT (Device Under Test).
class fifo_driver extends uvm_driver #(transaction);
  
  `uvm_component_utils(fifo_driver)  // Register the class with the UVM factory
  virtual fifo_if fif;               // Virtual interface to interact with the FIFO
 
  // Constructor for the driver class
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Build phase gets the virtual interface from the config database
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fifo_if)::get(this, "", "fif", fif))  // Fetch the interface set in tb
      `uvm_fatal("NOVIF", "Virtual interface 'fif' not found in config_db")
  endfunction

  // Run phase resets the DUT and then keeps driving transactions from the sequencer
  task run_phase(uvm_phase phase);
    do_reset();                              // Reset the DUT first
    forever begin
      seq_item_port.get_next_item(req);      // Retrieve a transaction from the sequencer
      if (req.oper == 1'b1)                  // If operation is write
        do_write(req);
      else                                   // If operation is read
        do_read();
      seq_item_port.item_done();             // Tell the sequencer this item is finished
    end
  endtask
 
  // Task to reset the DUT
  task do_reset();
    fif.rst     <= 1'b1;  // Assert the reset signal
    fif.rd      <= 1'b0;  // Deassert read control
    fif.wr      <= 1'b0;  // Deassert write control
    fif.data_in <= '0;    // Clear data input
    repeat (5) @(posedge fif.clock);  // Wait for a few clock cycles
    fif.rst     <= 1'b0;  // Deassert the reset signal
    `uvm_info("DRV", "DUT reset done", UVM_LOW)
  endtask
   
  // Task to write data to the FIFO (wr is high for exactly one clock edge)
  task do_write(transaction tr);
    @(posedge fif.clock);        // Wait for a positive edge of the clock
    fif.rd      <= 1'b0;
    fif.wr      <= 1'b1;         // Assert write control
    fif.data_in <= tr.data_in;   // Drive the data from the transaction
    @(posedge fif.clock);        // The DUT samples wr and data_in on this edge
    fif.wr      <= 1'b0;         // Deassert write control
    `uvm_info("DRV", $sformatf("WRITE data:%0d", tr.data_in), UVM_MEDIUM)
    @(posedge fif.clock);        // One idle cycle between operations
  endtask
  
  // Task to read data from the FIFO (rd is high for exactly one clock edge)
  task do_read();  
    @(posedge fif.clock);        // Wait for a positive edge of the clock
    fif.wr <= 1'b0;
    fif.rd <= 1'b1;              // Assert read control
    @(posedge fif.clock);        // The DUT samples rd on this edge
    fif.rd <= 1'b0;              // Deassert read control
    `uvm_info("DRV", "READ", UVM_MEDIUM)
    @(posedge fif.clock);        // One idle cycle between operations
  endtask
  
endclass

///////////////////////////////////////////////////////

// Monitor class observes the FIFO pins and sends what it sees to the scoreboard.
class fifo_monitor extends uvm_monitor;
 
  `uvm_component_utils(fifo_monitor)          // Register the class with the UVM factory
  virtual fifo_if fif;                        // Virtual interface to interact with the FIFO
  uvm_analysis_port #(transaction) ap;        // Port to broadcast observed transactions (replaces the mailbox)
  
  // Constructor for the monitor class
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Build phase creates the analysis port and gets the virtual interface
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);                     // Create the analysis port
    if (!uvm_config_db#(virtual fifo_if)::get(this, "", "fif", fif))
      `uvm_fatal("NOVIF", "Virtual interface 'fif' not found in config_db")
  endfunction
 
  // Task to continuously monitor the FIFO
  task run_phase(uvm_phase phase);
    transaction tr;                           // Transaction object for monitoring and logging
    
    forever begin
      @(posedge fif.clock);                   // Wait for a positive edge of the clock
      if (!fif.rst && (fif.wr || fif.rd)) begin   // Only record cycles where a write or read is requested
        tr = transaction::type_id::create("mon_tr");  // Create a new transaction object
        tr.wr      = fif.wr;                  // Capture the write control signal
        tr.rd      = fif.rd;                  // Capture the read control signal
        tr.data_in = fif.data_in;             // Capture the data input
        tr.full    = fif.full;                // Capture the full flag
        tr.empty   = fif.empty;               // Capture the empty flag
        
        if (fif.rd && !fif.wr) begin          // For a read, the output data is registered in the DUT
          @(posedge fif.clock);               // Wait one more clock edge for dout to become valid
          tr.data_out = fif.data_out;         // Capture the data output
        end
        
        `uvm_info("MON", tr.convert2string(), UVM_MEDIUM)
        ap.write(tr);                         // Send the captured transaction to the scoreboard
      end
    end
  endtask
  
endclass

/////////////////////////////////////////////////////

// Scoreboard class verifies the FIFO behavior against expected results.
class fifo_scoreboard extends uvm_scoreboard;
  
  `uvm_component_utils(fifo_scoreboard)                       // Register the class with the UVM factory
  uvm_analysis_imp #(transaction, fifo_scoreboard) imp;       // Port that receives transactions from the monitor
  
  bit [7:0] q[$];          // Queue acting as the reference model (stores written data)
  int err     = 0;         // Error counter for mismatch detection
  int n_wr    = 0;         // Number of writes accepted by the FIFO
  int n_rd    = 0;         // Number of reads that were checked
  int n_full  = 0;         // Number of write attempts while the FIFO was full
  int n_empty = 0;         // Number of read attempts while the FIFO was empty
  
  // Constructor for the scoreboard class
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Build phase creates the receiving port
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    imp = new("imp", this);
  endfunction
 
  // Function called automatically every time the monitor sends a transaction
  function void write(transaction tr);
    bit [7:0] expected;      // Expected data taken from the queue
    `uvm_info("SCO", tr.convert2string(), UVM_MEDIUM)
      
    if (tr.wr == 1'b1) begin          // If the operation is write
      if (tr.full == 1'b0) begin      // If the FIFO is not full
        q.push_back(tr.data_in);      // Store the data in the queue
        n_wr++;
        `uvm_info("SCO", $sformatf("DATA STORED IN QUEUE :%0d (size %0d)", tr.data_in, q.size()), UVM_HIGH)
      end
      else begin
        n_full++;                     // Write was ignored because the FIFO is full
        `uvm_info("SCO", "FIFO is full", UVM_MEDIUM)
      end
    end
    
    else if (tr.rd == 1'b1) begin     // If the operation is read
      if (tr.empty == 1'b0) begin     // If the FIFO is not empty
        expected = q.pop_front();     // Retrieve the expected (oldest) data from the queue
        n_rd++;
        
        if (tr.data_out == expected)  // Compare expected and actual data
          `uvm_info("SCO", $sformatf("DATA MATCH (%0d)", expected), UVM_MEDIUM)
        else begin
          err++;                      // Increment error count
          `uvm_error("SCO", $sformatf("DATA MISMATCH: expected %0d, got %0d", expected, tr.data_out))  // Report a mismatch
        end
      end
      else begin
        n_empty++;                    // Read was ignored because the FIFO is empty
        `uvm_info("SCO", "FIFO IS EMPTY", UVM_MEDIUM)
      end
    end
  endfunction

  // Report phase runs at the end of the simulation and prints the final result
  function void report_phase(uvm_phase phase);
    `uvm_info("SCO", "-------------------------------------------", UVM_NONE)
    `uvm_info("SCO", $sformatf("Writes accepted:%0d  Reads checked:%0d  Writes-while-full:%0d  Reads-while-empty:%0d",
                               n_wr, n_rd, n_full, n_empty), UVM_NONE)
    if (err == 0) `uvm_info("SCO", "TEST PASSED : Error Count 0", UVM_NONE)
    else          `uvm_error("SCO", $sformatf("TEST FAILED : Error Count %0d", err))
    `uvm_info("SCO", "-------------------------------------------", UVM_NONE)
  endfunction
  
endclass

///////////////////////////////////////////////////////

// Agent class groups the driver, monitor and sequencer for the FIFO interface.
class fifo_agent extends uvm_agent;
  
  `uvm_component_utils(fifo_agent)             // Register the class with the UVM factory
  fifo_driver                  drv;            // Driver to send transactions to the DUT
  fifo_monitor                 mon;            // Monitor to observe the DUT behavior
  uvm_sequencer #(transaction) seqr;           // Sequencer that passes transactions from sequences to the driver
  
  // Constructor for the agent class
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Build phase creates the components using the factory
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv  = fifo_driver::type_id::create("drv", this);
    mon  = fifo_monitor::type_id::create("mon", this);
    seqr = uvm_sequencer #(transaction)::type_id::create("seqr", this);
  endfunction

  // Connect phase links the driver to the sequencer
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction
  
endclass

///////////////////////////////////////////////////////

// Define the environment class which encapsulates all components of the testbench
class fifo_env extends uvm_env;
  
  `uvm_component_utils(fifo_env)    // Register the class with the UVM factory
  fifo_agent      agent;            // Agent containing the driver, monitor and sequencer
  fifo_scoreboard sco;              // Scoreboard to track and verify the results
  
  // Constructor for the environment class
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Build phase creates the agent and the scoreboard
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = fifo_agent::type_id::create("agent", this);
    sco   = fifo_scoreboard::type_id::create("sco", this);
  endfunction

  // Connect phase links the monitor's analysis port to the scoreboard
  function void connect_phase(uvm_phase phase);
    agent.mon.ap.connect(sco.imp);
  endfunction
  
endclass

///////////////////////////////////////////////////////

// Test class builds the environment and decides which sequences to run
class fifo_test extends uvm_test;
  
  `uvm_component_utils(fifo_test)   // Register the class with the UVM factory
  fifo_env env;                     // Environment instance
  
  // Constructor for the test class
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Build phase creates the environment
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = fifo_env::type_id::create("env", this);
  endfunction

  // Run phase starts the sequences on the agent's sequencer
  task run_phase(uvm_phase phase);
    fifo_rand_seq       rseq;       // Random read/write sequence
    fifo_fill_drain_seq fseq;       // Overfill then over-drain sequence

    phase.raise_objection(this);    // Keep the simulation alive until the test is done

    rseq = fifo_rand_seq::type_id::create("rseq");
    rseq.num_txn = 50;              // Set the number of random transactions
    rseq.start(env.agent.seqr);     // Run the random sequence

    fseq = fifo_fill_drain_seq::type_id::create("fseq");
    fseq.start(env.agent.seqr);     // Run the fill/drain sequence

    #200;                           // Let the monitor and scoreboard finish the last read
    phase.drop_objection(this);     // Allow the simulation to end
  endtask
  
endclass

///////////////////////////////////////////////////////

// Testbench module to instantiate and connect the DUT with the UVM environment
module tb;
    
  fifo_if fif();  // Instantiate the FIFO interface
  FIFO dut (fif.clock, fif.rst, fif.wr, fif.rd, fif.data_in, fif.data_out, fif.empty, fif.full);
  // Instantiate the FIFO DUT and connect it to the interface signals
    
  // Initial block to initialize the interface signals
  initial begin
    fif.clock   = 0;  // Initialize the clock to 0
    fif.rst     = 1;  // Start in reset
    fif.rd      = 0;
    fif.wr      = 0;
    fif.data_in = 0;
  end
    
  // Generate a clock signal with a period of 20 time units
  always #10 fif.clock <= ~fif.clock;
    
  // Initial block to share the interface with the UVM components and start the test
  initial begin
    uvm_config_db#(virtual fifo_if)::set(null, "*", "fif", fif);  // Make the interface visible to all components
    run_test("fifo_test");                                        // Create and run the UVM test
  end
    
  // Initial block to set up waveform dumping for simulation analysis
  initial begin
    $dumpfile("dump.vcd");  // Specify the VCD file for waveform dumping
    $dumpvars;              // Dump all variables for waveform analysis
  end
   
endmodule