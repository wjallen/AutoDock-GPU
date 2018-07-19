// Gradient-based steepest descent minimizer
// Alternative to Solis-Wetts

//#define DEBUG_ENERGY_KERNEL5
	//#define PRINT_ENERGIES
	//#define PRINT_GENES_AND_GRADS
	//#define PRINT_ATOMIC_COORDS

#define DEBUG_MINIMIZER
	#define PRINT_MINIMIZER_ENERGY_EVOLUTION

#define DEBUG_INITIAL_2BRT

__kernel void __attribute__ ((reqd_work_group_size(NUM_OF_THREADS_PER_BLOCK,1,1)))
gradient_minimizer(	
			char   dockpars_num_of_atoms,
			char   dockpars_num_of_atypes,
			int    dockpars_num_of_intraE_contributors,
			char   dockpars_gridsize_x,
			char   dockpars_gridsize_y,
			char   dockpars_gridsize_z,
							    		// g1 = gridsize_x
			uint   dockpars_gridsize_x_times_y, 		// g2 = gridsize_x * gridsize_y
			uint   dockpars_gridsize_x_times_y_times_z,	// g3 = gridsize_x * gridsize_y * gridsize_z
			float  dockpars_grid_spacing,
	 __global const float* restrict dockpars_fgrids, // This is too large to be allocated in __constant 
			int    dockpars_rotbondlist_length,
			float  dockpars_coeff_elec,
			float  dockpars_coeff_desolv,
	  __global      float* restrict dockpars_conformations_next,
	  __global      float* restrict dockpars_energies_next,
  	  __global 	int*   restrict dockpars_evals_of_new_entities,
	  __global      uint*  restrict dockpars_prng_states,
			int    dockpars_pop_size,
			int    dockpars_num_of_genes,
			float  dockpars_lsearch_rate,
			uint   dockpars_num_of_lsentities,
			uint   dockpars_max_num_of_iters,
			float  dockpars_qasp,
	     __constant float* atom_charges_const,
    	     __constant char*  atom_types_const,
	     __constant char*  intraE_contributors_const,
                        float  dockpars_smooth,
 	     __constant float* reqm,
	     __constant float* reqm_hbond,
	     __constant uint*  atom1_types_reqm,
	     __constant uint*  atom2_types_reqm,
    	     __constant float* VWpars_AC_const,
    	     __constant float* VWpars_BD_const,
             __constant float* dspars_S_const,
             __constant float* dspars_V_const,
             __constant int*   rotlist_const,
    	     __constant float* ref_coords_x_const,
    	     __constant float* ref_coords_y_const,
             __constant float* ref_coords_z_const,
    	     __constant float* rotbonds_moving_vectors_const,
             __constant float* rotbonds_unit_vectors_const,
             __constant float* ref_orientation_quats_const,
	     __constant int*   rotbonds_const,
	     __constant int*   rotbonds_atoms_const,
	     __constant int*   num_rotating_atoms_per_rotbond_const
			,
	     __constant float* angle_const,
	     __constant float* dependence_on_theta_const,
	     __constant float* dependence_on_rotangle_const
)
//The GPU global function performs gradient-based minimization on (some) entities of conformations_next.
//The number of OpenCL compute units (CU) which should be started equals to num_of_minEntities*num_of_runs.
//This way the first num_of_lsentities entity of each population will be subjected to local search
//(and each CU carries out the algorithm for one entity).
//Since the first entity is always the best one in the current population,
//it is always tested according to the ls probability, and if it not to be
//subjected to local search, the entity with ID num_of_lsentities is selected instead of the first one (with ID 0).
{
	// -----------------------------------------------------------------------------
	// Determining entity, and its run, energy, and genotype
	__local int   entity_id;
	__local int   run_id;
  	__local float energy;
	__local float genotype[ACTUAL_GENOTYPE_LENGTH];

	// Iteration counter fot the minimizer
  	__local uint iteration_cnt;  	

	// Stepsize for the minimizer
	__local float stepsize;

	if (get_local_id(0) == 0)
	{
		// Choosing a random entity out of the entire population
		/*
		run_id = get_group_id(0);
		//entity_id = (uint)(dockpars_pop_size * gpu_randf(dockpars_prng_states));
		entity_id = 0;
		*/

		run_id = get_group_id(0) / dockpars_num_of_lsentities;
		entity_id = get_group_id(0) % dockpars_num_of_lsentities;

		// Since entity 0 is the best one due to elitism,
		// it should be subjected to random selection
		if (entity_id == 0) {
			// If entity 0 is not selected according to LS-rate,
			// choosing an other entity
			if (100.0f*gpu_randf(dockpars_prng_states) > dockpars_lsearch_rate) {
				entity_id = dockpars_num_of_lsentities;					
			}
		}
		
		energy = dockpars_energies_next[run_id*dockpars_pop_size+entity_id];

		#if defined (DEBUG_MINIMIZER) || defined (PRINT_MINIMIZER_ENERGY_EVOLUTION)
		printf("\nrun_id:  %5u entity_id: %5u  initial_energy: %.6f\n", run_id, entity_id, energy);
		#endif

		// Initializing gradient-minimizer counters and flags
    		iteration_cnt  = 0;
		stepsize       = STEP_START;

		#if defined (DEBUG_MINIMIZER) || defined (PRINT_MINIMIZER_ENERGY_EVOLUTION)
		printf("\ninitial stepsize: %.6f", stepsize);
		#endif
	}

	barrier(CLK_LOCAL_MEM_FENCE);

  	event_t ev = async_work_group_copy(genotype,
  			      		   dockpars_conformations_next+(run_id*dockpars_pop_size+entity_id)*GENOTYPE_LENGTH_IN_GLOBMEM,
                              		   dockpars_num_of_genes, 0);

	// Asynchronous copy should be finished by here
	wait_group_events(1,&ev);

  	// -----------------------------------------------------------------------------
	           
	// Partial results of the gradient step
	__local float gradient          [ACTUAL_GENOTYPE_LENGTH];
	__local float candidate_energy;
	__local float candidate_genotype[ACTUAL_GENOTYPE_LENGTH];

	// Dummy variable used only for the first gpu_calc_gradient() call.
	// The corresponding energy for "genotype" is stored in "energy"
	__local float dummy_energy; 	

	// -------------------------------------------------------------------
	// Calculate gradients (forces) for intermolecular energy
	// Derived from autodockdev/maps.py
	// -------------------------------------------------------------------
	// Gradient of the intermolecular energy per each ligand atom
	// Also used to store the accummulated gradient per each ligand atom
	__local float gradient_inter_x[MAX_NUM_OF_ATOMS];
	__local float gradient_inter_y[MAX_NUM_OF_ATOMS];
	__local float gradient_inter_z[MAX_NUM_OF_ATOMS];

	// Gradient of the intramolecular energy per each ligand atom
	__local float gradient_intra_x[MAX_NUM_OF_ATOMS];
	__local float gradient_intra_y[MAX_NUM_OF_ATOMS];
	__local float gradient_intra_z[MAX_NUM_OF_ATOMS];

	// Ligand-atom position and partial energies
	__local float calc_coords_x[MAX_NUM_OF_ATOMS];
	__local float calc_coords_y[MAX_NUM_OF_ATOMS];
	__local float calc_coords_z[MAX_NUM_OF_ATOMS];
	__local float partial_energies[NUM_OF_THREADS_PER_BLOCK];

	#if defined (DEBUG_ENERGY_KERNEL)
	__local float partial_interE[NUM_OF_THREADS_PER_BLOCK];
	__local float partial_intraE[NUM_OF_THREADS_PER_BLOCK];
	#endif

	// Enable this for start debugging from a defined genotype
	#if defined (DEBUG_INITIAL_2BRT)
	// 2brt
	genotype[0] = 24.093334;
	genotype[1] = 24.658667;
	genotype[2] = 24.210667;
	genotype[3] = 50.0;
	genotype[4] = 50.0;
	genotype[5] = 50.0;
	genotype[6] = 0.0f;
	genotype[7] = 0.0f;
	genotype[8] = 0.0f;
	genotype[9] = 0.0f;
	genotype[10] = 0.0f;
	genotype[11] = 0.0f;
	genotype[12] = 0.0f;
	genotype[13] = 0.0f;
	genotype[14] = 0.0f;
	genotype[15] = 0.0f;
	genotype[16] = 0.0f;
	genotype[17] = 0.0f;
	genotype[18] = 0.0f;
	genotype[19] = 0.0f;
	genotype[20] = 0.0f;
	#endif

	// -----------------------------------------------------------------------------
	// Calculating gradient
	barrier(CLK_LOCAL_MEM_FENCE);

	// =============================================================
	gpu_calc_gradient(
			dockpars_rotbondlist_length,
			dockpars_num_of_atoms,
			dockpars_gridsize_x,
			dockpars_gridsize_y,
			dockpars_gridsize_z,
								// g1 = gridsize_x
			dockpars_gridsize_x_times_y, 		// g2 = gridsize_x * gridsize_y
			dockpars_gridsize_x_times_y_times_z,	// g3 = gridsize_x * gridsize_y * gridsize_z
			dockpars_fgrids,
			dockpars_num_of_atypes,
			dockpars_num_of_intraE_contributors,
			dockpars_grid_spacing,
			dockpars_coeff_elec,
			dockpars_qasp,
			dockpars_coeff_desolv,
			// Some OpenCL compilers don't allow declaring 
			// local variables within non-kernel functions.
			// These local variables must be declared in a kernel, 
			// and then passed to non-kernel functions.
			genotype,
			&dummy_energy,
			&run_id,

			calc_coords_x,
			calc_coords_y,
			calc_coords_z,

			atom_charges_const,
			atom_types_const,
			intraE_contributors_const,
			dockpars_smooth,
			reqm,
			reqm_hbond,
		     	atom1_types_reqm,
		     	atom2_types_reqm,
			VWpars_AC_const,
			VWpars_BD_const,
			dspars_S_const,
			dspars_V_const,
			rotlist_const,
			ref_coords_x_const,
			ref_coords_y_const,
			ref_coords_z_const,
			rotbonds_moving_vectors_const,
			rotbonds_unit_vectors_const,
			ref_orientation_quats_const,
			rotbonds_const,
			rotbonds_atoms_const,
			num_rotating_atoms_per_rotbond_const
			,
	     		angle_const,
	     		dependence_on_theta_const,
	     		dependence_on_rotangle_const
			// Gradient-related arguments
			// Calculate gradients (forces) for intermolecular energy
			// Derived from autodockdev/maps.py
			,
			dockpars_num_of_genes,
			gradient_inter_x,
			gradient_inter_y,
			gradient_inter_z,
			gradient_intra_x,
			gradient_intra_y,
			gradient_intra_z,
			gradient
			);
	// =============================================================

	#if defined (DEBUG_INITIAL_2BRT)

	// Evaluating candidate
	barrier(CLK_LOCAL_MEM_FENCE);

	// =============================================================
	gpu_calc_energy(dockpars_rotbondlist_length,
			dockpars_num_of_atoms,
			dockpars_gridsize_x,
			dockpars_gridsize_y,
			dockpars_gridsize_z,
							    	// g1 = gridsize_x
			dockpars_gridsize_x_times_y, 		// g2 = gridsize_x * gridsize_y
			dockpars_gridsize_x_times_y_times_z,	// g3 = gridsize_x * gridsize_y * gridsize_z
			dockpars_fgrids,
			dockpars_num_of_atypes,
			dockpars_num_of_intraE_contributors,
			dockpars_grid_spacing,
			dockpars_coeff_elec,
			dockpars_qasp,
			dockpars_coeff_desolv,
			/*candidate_genotype,*/ genotype, /*WARNING: here "genotype" is used to calculate the energy of the manually specified genotype*/
			&energy,
			&run_id,
			// Some OpenCL compilers don't allow declaring 
			// local variables within non-kernel functions.
			// These local variables must be declared in a kernel, 
			// and then passed to non-kernel functions.
			calc_coords_x,
			calc_coords_y,
			calc_coords_z,
			partial_energies,
			#if defined (DEBUG_ENERGY_KERNEL)
			partial_interE,
			partial_intraE,
			#endif

			atom_charges_const,
			atom_types_const,
			intraE_contributors_const,
#if 0
			true,
#endif
			dockpars_smooth,
			reqm,
			reqm_hbond,
	     	        atom1_types_reqm,
	     	        atom2_types_reqm,
			VWpars_AC_const,
			VWpars_BD_const,
			dspars_S_const,
			dspars_V_const,
			rotlist_const,
			ref_coords_x_const,
			ref_coords_y_const,
			ref_coords_z_const,
			rotbonds_moving_vectors_const,
			rotbonds_unit_vectors_const,
			ref_orientation_quats_const
			);
	// =============================================================

	if (get_local_id(0) == 0)
	{
		printf("\ninitial_energy: %.6f\n", energy);
		printf("\ninitial stepsize: %.6f", stepsize);
	}
	barrier(CLK_LOCAL_MEM_FENCE);
	#endif

	// Perform gradient-descent iterations

	#if 0
	// 7cpa
	float grid_center_x = 49.836;
	float grid_center_y = 17.609;
	float grid_center_z = 36.272;
	float ligand_center_x = 49.2216976744186;
	float ligand_center_y = 17.793953488372097;
	float ligand_center_z = 36.503837209302326;
	float shoemake_gene_u1 = 0.02;
	float shoemake_gene_u2 = 0.23;
	float shoemake_gene_u3 = 0.95;
	#endif

	#if 0
	// 3tmn
	float grid_center_x = 52.340;
	float grid_center_y = 15.029;
	float grid_center_z = -2.932;
	float ligand_center_x = 52.22740741;
	float ligand_center_y = 15.51751852;
	float ligand_center_z = -2.40896296;
	#endif

	// No need for defining upper and lower genotype bounds
	#if 0
	// Defining lower and upper bounds for genotypes
	__local float lower_bounds_genotype[ACTUAL_GENOTYPE_LENGTH];
	__local float upper_bounds_genotype[ACTUAL_GENOTYPE_LENGTH];

	for (uint gene_counter = get_local_id(0);
	          gene_counter < dockpars_num_of_genes;
	          gene_counter+= NUM_OF_THREADS_PER_BLOCK) {
		// Translation genes ranges are within the gridbox
		if (gene_counter <= 2) {
			lower_bounds_genotype [gene_counter] = 0.0f;
			upper_bounds_genotype [gene_counter] = (gene_counter == 0) ? dockpars_gridsize_x: 
							       (gene_counter == 1) ? dockpars_gridsize_y: 
										     dockpars_gridsize_z;
		// Orientation and torsion genes range between [0, 360]
		// See auxiliary_genetic.cl/map_angle()
		} else {
			lower_bounds_genotype [gene_counter] = 0.0f;
			upper_bounds_genotype [gene_counter] = 360.0f;
		}

		#if defined (DEBUG_MINIMIZER)
		//printf("(%-3u) %-0.7f %-10.7f %-10.7f %-10.7f\n", gene_counter, stepsize, genotype[gene_counter], lower_bounds_genotype[gene_counter], upper_bounds_genotype[gene_counter]);
		#endif
	}
	barrier(CLK_LOCAL_MEM_FENCE);
	#endif

	// Calculating maximum possible stepsize (alpha)
	__local float max_trans_grad, max_rota_grad, max_tors_grad;
	__local float max_trans_stepsize, max_rota_stepsize, max_tors_stepsize;
	__local float max_stepsize;

	// Storing torsion gradients here
	__local float torsions_gradient[ACTUAL_GENOTYPE_LENGTH];

	// The termination criteria is based on 
	// a maximum number of iterations, and
	// the minimum step size allowed for single-floating point numbers 
	// (IEEE-754 single float has a precision of about 6 decimal digits)
	do {
		#if 0
		// Specific input genotypes for a ligand with no rotatable bonds (1ac8).
		// Translation genes must be expressed in grids in OCLADock (genotype [0|1|2]).
		// However, for testing purposes, 
		// we start using translation values in real space (Angstrom): {31.79575, 93.743875, 47.699875}
		// Rotation genes are expresed in the Shoemake space: genotype [3|4|5]
		// xyz_gene_gridspace = gridcenter_gridspace + (input_gene_realspace - gridcenter_realspace)/gridsize

		// 1ac8				
		genotype[0] = 30 + (31.79575  - 31.924) / 0.375;
		genotype[1] = 30 + (93.743875 - 93.444) / 0.375;
		genotype[2] = 30 + (47.699875 - 47.924) / 0.375;
		genotype[3] = 0.1f;
		genotype[4] = 0.5f;
		genotype[5] = 0.9f;
		#endif

		#if 0
		// 3tmn
		genotype[0] = 30 + (ligand_center_x - grid_center_x) / 0.375;
		genotype[1] = 30 + (ligand_center_y - grid_center_y) / 0.375;
		genotype[2] = 30 + (ligand_center_z - grid_center_z) / 0.375;
		genotype[3] = shoemake_gene_u1;
		genotype[4] = shoemake_gene_u2;
		genotype[5] = shoemake_gene_u3;
		genotype[6] = 0.0f;
		genotype[7] = 0.0f;
		genotype[8] = 0.0f;
		genotype[9] = 0.0f;
		genotype[10] = 0.0f;
		genotype[11] = 0.0f;
		genotype[12] = 0.0f;
		genotype[13] = 0.0f;
		genotype[14] = 0.0f;
		genotype[15] = 0.0f;
		genotype[16] = 0.0f;
		genotype[17] = 0.0f;
		genotype[18] = 0.0f;
		genotype[19] = 0.0f;
		genotype[20] = 0.0f;
		#endif

		#if 0
		// 2j5s
		genotype[0] = 28.464;
		genotype[1] = 25.792762;
		genotype[2] = 23.740571;
		genotype[3] = 50.0;
		genotype[4] = 50.0;
		genotype[5] = 50.0;
		genotype[6] = 0.0f;
		genotype[7] = 0.0f;
		genotype[8] = 0.0f;
		genotype[9] = 0.0f;
		genotype[10] = 0.0f;
		genotype[11] = 0.0f;
		genotype[12] = 0.0f;
		genotype[13] = 0.0f;
		genotype[14] = 0.0f;
		genotype[15] = 0.0f;
		genotype[16] = 0.0f;
		genotype[17] = 0.0f;
		genotype[18] = 0.0f;
		genotype[19] = 0.0f;
		genotype[20] = 0.0f;
		#endif

		#if 0
		// 2brt
		genotype[0] = 24.093334;
		genotype[1] = 24.658667;
		genotype[2] = 24.210667;
		genotype[3] = 50.0;
		genotype[4] = 50.0;
		genotype[5] = 50.0;
		genotype[6] = 0.0f;
		genotype[7] = 0.0f;
		genotype[8] = 0.0f;
		genotype[9] = 0.0f;
		genotype[10] = 0.0f;
		genotype[11] = 0.0f;
		genotype[12] = 0.0f;
		genotype[13] = 0.0f;
		genotype[14] = 0.0f;
		genotype[15] = 0.0f;
		genotype[16] = 0.0f;
		genotype[17] = 0.0f;
		genotype[18] = 0.0f;
		genotype[19] = 0.0f;
		genotype[20] = 0.0f;
		#endif

		if (get_local_id(0) == 0) {
			// Finding maximum of the absolute value for the three translation gradients
			max_trans_grad = fmax(fabs(gradient[0]), fabs(gradient[1]));
			max_trans_grad = fmax(max_trans_grad, fabs(gradient[2]));

			// MAX_DEV_TRANSLATION needs to be expressed in grid size first
			max_trans_stepsize = native_divide(native_divide(MAX_DEV_TRANSLATION, dockpars_grid_spacing), max_trans_grad);

			// Finding maximum of the absolute value for the three rotation gradients
			max_rota_grad = fmax(fabs(gradient[3]), fabs(gradient[4]));	
			max_rota_grad = fmax(max_rota_grad, fabs(gradient[5]));	

			// Note that MAX_DEV_ROTATION
			// is already expressed within [0, 1]
			max_rota_stepsize = native_divide(MAX_DEV_ROTATION, max_rota_grad);
		}

		// Copying torsions genes
		for(uint i = get_local_id(0); 
			 i < dockpars_num_of_genes-6; 
			 i+= NUM_OF_THREADS_PER_BLOCK) {
			torsions_gradient[i] = fabs(gradient[i+6]);
		}
		barrier(CLK_LOCAL_MEM_FENCE);

		// Calculating maximum absolute torsional gene
		// https://stackoverflow.com/questions/36465581/opencl-find-max-in-array
		for (uint i=(dockpars_num_of_genes-6)/2; i>=1; i/=2){
			if (get_local_id(0) < i) {

			#if 0
			#if defined (DEBUG_MINIMIZER)
			printf("---====--- %u %u %10.10f %-0.10f\n", i, get_local_id(0), torsions_gradient[get_local_id(0)], torsions_gradient[get_local_id(0) + i]);
			#endif
			#endif

				if (torsions_gradient[get_local_id(0)] < torsions_gradient[get_local_id(0) + i]) {
					torsions_gradient[get_local_id(0)] = torsions_gradient[get_local_id(0) + i];
				}
			}
			barrier(CLK_LOCAL_MEM_FENCE);
		}
		if (get_local_id(0) == 0) {
			max_tors_grad = torsions_gradient[get_local_id(0)];
			max_tors_stepsize = native_divide(MAX_DEV_TORSION, max_tors_grad);
		}

		barrier(CLK_LOCAL_MEM_FENCE);

		if (get_local_id(0) == 0) {
			// Calculating the maximum stepsize using previous three
			max_stepsize = fmin(max_trans_stepsize, max_rota_stepsize);
			max_stepsize = fmin(max_stepsize, max_tors_stepsize);

			// Capping the stepsize
			stepsize = fmin(stepsize, max_stepsize);

			#if 1
			#if defined (DEBUG_MINIMIZER)


			// Enable it back if intermmediate details are needed
			#if 1
			for(uint i = 0; i < dockpars_num_of_genes; i++) {
				if (i == 0) {
					printf("\n%s\n", "----------------------------------------------------------");
					printf("\n%s\n", "Before calculating gradients:");
					printf("%13s %13s %5s %15s %20s\n", "gene_id", "gene", "|", "grad", " grad (devpy units)");
				}
				printf("%13u %13.6f %5s %15.6f %18.6f\n", i, genotype[i], "|", gradient[i], (i<3)? (gradient[i]/0.375f):(gradient[i]*180.0f/PI_FLOAT));
			}
			#endif

			// Enable it back if intermmediate details are needed
			# if 1			
			printf("\n");
			printf("%20s %10.6f\n", "max_trans_grad: ", max_trans_grad);
			printf("%20s %10.6f\n", "max_rota_grad: ", max_rota_grad);
			printf("%20s %10.6f\n", "max_tors_grad: ", max_tors_grad);
			#endif

			printf("\n");
			printf("%20s %10.6f\n", "max_trans_stepsize: ", max_trans_stepsize);
			printf("%20s %10.6f\n", "max_rota_stepsize: " , max_rota_stepsize);
			printf("%20s %10.6f\n", "max_tors_stepsize: " , max_tors_stepsize);

			printf("\n");
			printf("%20s %10.6f\n\n", "max_stepsize: ", max_stepsize);
			printf("%20s %10.6f\n\n", "stepsize: ", stepsize);
			#endif
			#endif
		}	

		// Calculating gradient
		barrier(CLK_LOCAL_MEM_FENCE);

		// =============================================================
		gpu_calc_gradient(
				dockpars_rotbondlist_length,
				dockpars_num_of_atoms,
				dockpars_gridsize_x,
				dockpars_gridsize_y,
				dockpars_gridsize_z,
								    	// g1 = gridsize_x
				dockpars_gridsize_x_times_y, 		// g2 = gridsize_x * gridsize_y
				dockpars_gridsize_x_times_y_times_z,	// g3 = gridsize_x * gridsize_y * gridsize_z
				dockpars_fgrids,
				dockpars_num_of_atypes,
				dockpars_num_of_intraE_contributors,
				dockpars_grid_spacing,
				dockpars_coeff_elec,
				dockpars_qasp,
				dockpars_coeff_desolv,
				// Some OpenCL compilers don't allow declaring 
				// local variables within non-kernel functions.
				// These local variables must be declared in a kernel, 
				// and then passed to non-kernel functions.
				genotype,
				&energy,
				&run_id,

				calc_coords_x,
				calc_coords_y,
				calc_coords_z,

			        atom_charges_const,
				atom_types_const,
				intraE_contributors_const,
				dockpars_smooth,
				reqm,
				reqm_hbond,
		     	        atom1_types_reqm,
		     	        atom2_types_reqm,
				VWpars_AC_const,
				VWpars_BD_const,
				dspars_S_const,
				dspars_V_const,
				rotlist_const,
				ref_coords_x_const,
				ref_coords_y_const,
				ref_coords_z_const,
				rotbonds_moving_vectors_const,
				rotbonds_unit_vectors_const,
				ref_orientation_quats_const,
				rotbonds_const,
				rotbonds_atoms_const,
				num_rotating_atoms_per_rotbond_const
				,
	     			angle_const,
	     			dependence_on_theta_const,
	     			dependence_on_rotangle_const
			 	// Gradient-related arguments
			 	// Calculate gradients (forces) for intermolecular energy
			 	// Derived from autodockdev/maps.py
				,
				dockpars_num_of_genes,
				gradient_inter_x,
				gradient_inter_y,
				gradient_inter_z,
				gradient_intra_x,
				gradient_intra_y,
				gradient_intra_z,
				gradient
				);
		// =============================================================

		// This could be enabled back for double checking
		#if 0
		#if defined (DEBUG_ENERGY_KERNEL5)	
		if (/*(get_group_id(0) == 0) &&*/ (get_local_id(0) == 0)) {
		
			#if defined (PRINT_GENES_AND_GRADS)
			for(uint i = 0; i < dockpars_num_of_genes; i++) {
				if (i == 0) {
					printf("\n%s\n", "----------------------------------------------------------");
					printf("%13s %13s %5s %15s %15s\n", "gene_id", "gene.value", "|", "gene.grad", "(autodockdevpy units)");
				}
				printf("%13u %13.6f %5s %15.6f %15.6f\n", i, genotype[i], "|", gradient[i], (i<3)? (gradient[i]/0.375f):(gradient[i]*180.0f/PI_FLOAT));
			}
			#endif

			#if defined (PRINT_ATOMIC_COORDS)
			for(uint i = 0; i < dockpars_num_of_atoms; i++) {
				if (i == 0) {
					printf("\n%s\n", "----------------------------------------------------------");
					printf("%s\n", "Coordinates calculated by calcgradient.cl");
					printf("%12s %12s %12s %12s\n", "atom_id", "coords.x", "coords.y", "coords.z");
				}
				printf("%12u %12.6f %12.6f %12.6f\n", i, calc_coords_x[i], calc_coords_y[i], calc_coords_z[i]);
			}
			printf("\n");
			#endif
		}
		#endif
		#endif
		
		for(uint i = get_local_id(0); i < dockpars_num_of_genes; i+= NUM_OF_THREADS_PER_BLOCK) {
	     		// Taking step
			candidate_genotype[i] = genotype[i] - stepsize * gradient[i];	

			#if defined (DEBUG_MINIMIZER)
			//printf("(%-3u) %-0.7f %-10.7f %-10.7f %-10.7f\n", i, stepsize, genotype[i], gradient[i], candidate_genotype[i]);

			if (i == 0) {
				printf("\n%s\n", "After calculating gradients:");
				printf("%13s %13s %5s %15s %5s %20s\n", "gene_id", "gene", "|", "grad", "|", "cand_gene");
			}
			printf("%13u %13.6f %5s %15.6f %5s %18.6f\n", i, genotype[i], "|", gradient[i], "|", candidate_genotype[i]);
			#endif

			// No need for defining upper and lower genotype bounds
			#if 0
			// Putting genes back within bounds
			candidate_genotype[i] = fmin(candidate_genotype[i], upper_bounds_genotype[i]);
			candidate_genotype[i] = fmax(candidate_genotype[i], lower_bounds_genotype[i]);
			#endif
	   	}
		
		// Evaluating candidate
		barrier(CLK_LOCAL_MEM_FENCE);

		// =============================================================
		gpu_calc_energy(dockpars_rotbondlist_length,
				dockpars_num_of_atoms,
				dockpars_gridsize_x,
				dockpars_gridsize_y,
				dockpars_gridsize_z,
								    	// g1 = gridsize_x
				dockpars_gridsize_x_times_y, 		// g2 = gridsize_x * gridsize_y
				dockpars_gridsize_x_times_y_times_z,	// g3 = gridsize_x * gridsize_y * gridsize_z
				dockpars_fgrids,
				dockpars_num_of_atypes,
				dockpars_num_of_intraE_contributors,
				dockpars_grid_spacing,
				dockpars_coeff_elec,
				dockpars_qasp,
				dockpars_coeff_desolv,
				candidate_genotype, /*genotype,*/ /*WARNING: use "genotype" ONLY to reproduce results*/
				&candidate_energy,
				&run_id,
				// Some OpenCL compilers don't allow declaring 
				// local variables within non-kernel functions.
				// These local variables must be declared in a kernel, 
				// and then passed to non-kernel functions.
				calc_coords_x,
				calc_coords_y,
				calc_coords_z,
				partial_energies,
				#if defined (DEBUG_ENERGY_KERNEL)
				partial_interE,
				partial_intraE,
				#endif

				atom_charges_const,
				atom_types_const,
				intraE_contributors_const,
#if 0
				true,
#endif
				dockpars_smooth,
				reqm,
				reqm_hbond,
		     	        atom1_types_reqm,
		     	        atom2_types_reqm,
				VWpars_AC_const,
				VWpars_BD_const,
				dspars_S_const,
				dspars_V_const,
				rotlist_const,
				ref_coords_x_const,
				ref_coords_y_const,
				ref_coords_z_const,
				rotbonds_moving_vectors_const,
				rotbonds_unit_vectors_const,
				ref_orientation_quats_const
				);
		// =============================================================

		#if defined (DEBUG_ENERGY_KERNEL5)
		if (/*(get_group_id(0) == 0) &&*/ (get_local_id(0) == 0)) {
			#if defined (PRINT_ENERGIES)
			printf("\n");
			printf("%-10s %-10.6f \n", "intra: ",  partial_intraE[0]);
			printf("%-10s %-10.6f \n", "grids: ",  partial_interE[0]);
			printf("%-10s %-10.6f \n", "Energy: ", (partial_intraE[0] + partial_interE[0]));
			#endif

			#if defined (PRINT_GENES_AND_GRADS)
			for(uint i = 0; i < dockpars_num_of_genes; i++) {
				if (i == 0) {
					printf("\n%s\n", "----------------------------------------------------------");
					printf("%13s %13s %5s %15s %15s\n", "gene_id", "cand-gene.value"/* "gene.value"*/, "|", "gene.grad", "(autodockdevpy units)");
				}
				printf("%13u %13.6f %5s %15.6f %15.6f\n", i, candidate_genotype[i] /*genotype[i]*/, "|", gradient[i], (i<3)? (gradient[i]/0.375f):(gradient[i]*180.0f/PI_FLOAT));
			}
			#endif

			#if defined (PRINT_ATOMIC_COORDS)
			for(uint i = 0; i < dockpars_num_of_atoms; i++) {
				if (i == 0) {
					printf("\n%s\n", "----------------------------------------------------------");
					printf("%s\n", "Coordinates calculated by calcenergy.cl");
					printf("%12s %12s %12s %12s\n", "atom_id", "coords.x", "coords.y", "coords.z");
				}
				printf("%12u %12.6f %12.6f %12.6f\n", i, calc_coords_x[i], calc_coords_y[i], calc_coords_z[i]);
			}
			printf("\n");
			#endif
		}
		#endif

		#if defined (DEBUG_MINIMIZER)
		barrier(CLK_LOCAL_MEM_FENCE);
		if (get_local_id(0) == 0) {
			printf("\n");
			printf("%-20s %-13.6f\n", "Old energy: ", energy);
			printf("%-20s %-13.6f\n", "New energy: ", candidate_energy);
			printf("\n");
		}
		barrier(CLK_LOCAL_MEM_FENCE);
		#endif

		// Checking if E(candidate_genotype) < E(genotype)
		if (candidate_energy < energy){
			
			for(uint i = get_local_id(0); 
			 	 i < dockpars_num_of_genes; 
		 	 	 i+= NUM_OF_THREADS_PER_BLOCK) {


				#if defined (DEBUG_MINIMIZER)
				//printf("(%-3u) %-15.7f %-10.7f %-10.7f %-10.7f\n", i, stepsize, genotype[i], gradient[i], candidate_genotype[i]);

				if (i == 0) {
					printf("\n%s\n", "Energy improved! ... then update genotype and energy:");
					printf("%13s %13s %5s %15s\n", "gene_id", "old.gene", "|", "new.gene");
				}
				printf("%13u %13.6f %5s %15.6f\n", i, genotype[i], "|", candidate_genotype[i]);

				if (i == 0) {
					printf("\n");
					printf("%13s %5s %15s\n", "old.energy", "|", "new.energy");
					printf("%13.6f %5s %15.6f\n", energy, "|", candidate_energy);
				}	
				#endif				

				if (i == 0) {
				
					#if defined (DEBUG_MINIMIZER)
					printf("\n%s\n", "Energy improved! ... then increase step_size:");
					#endif

					// Updating energy
					energy = candidate_energy;

					// Increase stepsize
					stepsize *= STEP_INCREASE;
				}

				// Updating genotype
				genotype[i] = candidate_genotype[i];
			}
		}
		else { 
			#if defined (DEBUG_MINIMIZER)
			if (get_local_id(0) == 0) {
				printf("\n%s\n", "NO Energy improvement! ... then decrease stepsize:");
			}
			#endif		

			if (get_local_id(0) == 0) {
				stepsize *= STEP_DECREASE;
			}
		}

		barrier(CLK_LOCAL_MEM_FENCE);

		#if defined (DEBUG_MINIMIZER)
		if (get_local_id(0) == 0) {
			printf("\n");
			printf("%20s %10.6f\n\n", "stepsize: ", stepsize);
		}
		#endif

		// Updating number of stepest-descent iterations (energy evaluations)
		if (get_local_id(0) == 0) {
	    		iteration_cnt = iteration_cnt + 1;

			#if defined (DEBUG_MINIMIZER) || defined (PRINT_MINIMIZER_ENERGY_EVOLUTION)
			printf("# sd-iters: %-3u, stepsize: %10.10f, E: %10.6f\n", iteration_cnt, stepsize, energy);
			#endif

			#if defined (DEBUG_ENERGY_KERNEL5)
			printf("%-18s [%-5s]---{%-5s}   [%-10.7f]---{%-10.7f}\n", "-ENERGY-KERNEL5-", "GRIDS", "INTRA", partial_interE[0], partial_intraE[0]);
			#endif
		}

  	} while ((iteration_cnt < dockpars_max_num_of_iters) && (stepsize > 1E-8));

	#if defined (DEBUG_MINIMIZER) || defined (PRINT_MINIMIZER_ENERGY_EVOLUTION)
	if (get_local_id(0) == 0) {
		printf("Termination criteria: ( #sd-iters < %-3u ) && ( stepsize > %10.10f )\n", dockpars_max_num_of_iters, 1E-8);
	}
	#endif

	// -----------------------------------------------------------------------------

  	// Updating eval counter and energy
	if (get_local_id(0) == 0) {
		dockpars_evals_of_new_entities[run_id*dockpars_pop_size+entity_id] += iteration_cnt;
		dockpars_energies_next[run_id*dockpars_pop_size+entity_id] = energy;

		#if defined (DEBUG_MINIMIZER) || defined (PRINT_MINIMIZER_ENERGY_EVOLUTION)
		printf("-------> End of grad-min cycle, num of evals: %u, final energy: %.6f\n", iteration_cnt, energy);
		#endif
	}

	// Mapping torsion angles
	for (uint gene_counter = get_local_id(0);
	     	  gene_counter < dockpars_num_of_genes;
	          gene_counter+= NUM_OF_THREADS_PER_BLOCK) {
		   if (gene_counter >= 3) {
			    map_angle(&(genotype[gene_counter]));
		   }
	}

	// Updating old offspring in population
	barrier(CLK_LOCAL_MEM_FENCE);

	async_work_group_copy(dockpars_conformations_next+(run_id*dockpars_pop_size+entity_id)*GENOTYPE_LENGTH_IN_GLOBMEM,
			      genotype,
			      dockpars_num_of_genes, 0);
}
