package sim_util_pkg;

  class sample_discriminator_util #(
    parameter int SAMPLE_WIDTH = 16,
    parameter int PARALLEL_SAMPLES = 2
  );
  
    typedef logic signed [SAMPLE_WIDTH-1:0] signed_sample_t;
    
    // helper function to check if any of the parallel samples are above the high threshold
    // needed to replicate the behavior of the sample discriminator which starts saving
    // samples as soon as a sample arrives which is above the high threshold
    function logic any_above_high (
      input logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] samples_in,
      input logic [SAMPLE_WIDTH-1:0] threshold_high
    );
      for (int j = 0; j < PARALLEL_SAMPLES; j++) begin
        if (signed_sample_t'(samples_in[j*SAMPLE_WIDTH+:SAMPLE_WIDTH]) > signed_sample_t'(threshold_high)) begin
          return 1'b1;
        end
      end
      return 1'b0;
    endfunction
    
    // helper function to check if all parallel samples are below the low threshold
    // needed to replicate the behavior of the sample discriminator which stops saving
    // samples once all the samples it receives in a single clock cycle are below
    // the low threshold
    function logic all_below_low (
      input logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] samples_in,
      input logic [SAMPLE_WIDTH-1:0] threshold_low
    );
      for (int j = 0; j < PARALLEL_SAMPLES; j++) begin
        if (signed_sample_t'(samples_in[j*SAMPLE_WIDTH+:SAMPLE_WIDTH]) > signed_sample_t'(threshold_low)) begin
          return 1'b0;
        end
      end
      return 1'b1;
    endfunction
  
  endclass

  class generic #(type T=int);

    function T max(input T A, input T B);
      return (A > B) ? A : B;
    endfunction

    function T abs(input T x);
      return (x < 0) ? -x : x;
    endfunction

  endclass

endpackage
