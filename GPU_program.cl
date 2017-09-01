//#define USE_VARIABLE_BODY_FORCE

#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics : enable

#ifdef MY_USE_DOUBLE_PRECISION
typedef double Real;
#else
typedef float Real;
#endif

#define CASSON
#define MIN_TAU 0.505

#include "struct_header_device.h"

void equilibirum_distribution_D3Q19(float* f_eq, float rho, float u_x, float u_y, float u_z);
void stream_locations(int n_x, int n_y, int n_z, int i_x, int i_y, int i_z, int* ind);
void guo_body_force_term(float u_x, float u_y, float u_z,
	float g_x, float g_y, float g_z, float* fGuo);
float compute_tau(float srtII, __global float* params);

__kernel void fluid_boundary_forces_linear_stencil(
	__global float* gpf,
	__global float4* parKinematics, // Move particle data to local in future!
	__global float4* parForces,
	__global uint* pointIDs,
	__global uint* countPoints,
	__global int_param_struct* intDat)
{
	int nID = get_global_id(0); // 1D kernel execution
	int offset = 1; // 1 buffer layer

	// Get lattice size info, for writing body force dat
	int N_x = intDat->LatticeSize[0];
	int N_y = intDat->LatticeSize[1];
	int N_z = intDat->LatticeSize[2];
	int N_C = N_x*N_y*N_z; // Total nodes

	// Get particle ID for this node
	uint parNum = pointIDs[nID];
	//uint pointNum = pointIDs[nID + intDat->TotalSurfPoints];

	// Get particle kinetmatic data for this node
	float4 xp, vp, e1, e2, e3, angVel;
	for(int i = 0; i < 3; i++) {
		xp = parKinematics[parNum]; // Position
		vp = parKinematics[parNum + intDat->NumParticles]; // Velocity
		e1 = parKinematics[parNum + 2*intDat->NumParticles]; //
		e2 = parKinematics[parNum + 3*intDat->NumParticles];
		e3 = parKinematics[parNum + 4*intDat->NumParticles];
		angVel = parKinematics[parNum + 5*intDat->NumParticles];
	}

	// Lookup original position of this point relative to particle center
	float4 r;
	float4 r2 = (float4){0.0, 0.0, 0.0, 0.0};

	// Apply rotaiton
	r2 = e1*r.x + e2*r.y + e3*r.z;

	// Absolute position of point
	float4 rp = xp + r2;

	// Adjust for pbc
	float4 w = (float4)(N_x-3, N_y-3, N_z-3, 0);
	float4 rpp = fmod(rp,w);

	// Location of corner closest to origin
	int i_xf = floor(rpp.x) + offset;
	int i_yf = floor(rpp.y) + offset;
	int i_zf = floor(rpp.z) + offset;
	
	// Stencil weightings
	int sten[8][3] = {{0,0,0}, {0,0,1}, {0,1,0}, {0,1,1}, {1,0,0}, {1,0,1}, {1,1,0}, {1,1,1}};
	float wn[8];
	
	for(int n = 0; n < 8; n++) {
		wn[n] = 0.0;
	}
	
	// Interpolate velocity
	float4 u;

	// Calculate velocity of node
	float4 v = vp + cross(angVel,r); // Order is important


	// Direct forcing velocity delta
	float4 ud = v - u;

	// Distribute force to 8 nodes

	
	for(int n = 0; n < 8; n++) {

		int dx = sten[n][0];
		int dy = sten[n][1];
		int dz = sten[n][2];
		int i_n = (i_xf+dx) + N_x*((i_yf+dy) + N_y*(i_zf+dz));
		
		int p = atomic_inc(&countPoints[i_n]); // The p'th time a surface point writes to this node
		gpf[i_n + N_C*(3*p)    ] += ud.x;
		gpf[i_n + N_C*(3*p + 1)] += ud.y;
		gpf[i_n + N_C*(3*p + 2)] += ud.z;
	}

}


__kernel void collideMRT_stream_D3Q19(
	__global float* f_c,
	__global float* f_s,
	__global float* gpf,
	__global float* u,
	__global float* tau_p,
	__global int_param_struct* intDat,
	__global flp_param_struct* flpDat) // Params could be const or local if supported
{
	//printf(">> collideMRT_stream_D3Q19 <<");
	
	// Get 3D indices
	int i_x = get_global_id(0); // Using global_work_offset to take buffer layer into account
	int i_y = get_global_id(1);
	int i_z = get_global_id(2);

	// Convention: upper-case N for total lattice array size (including buffer)
	int N_x = intDat->LatticeSize[0];
	int N_y = intDat->LatticeSize[1];
	int N_z = intDat->LatticeSize[2];

	// 1D index
	int i_1D = i_x + N_x*(i_y + N_y*i_z);
	int N_C = N_x*N_y*N_z; // Total nodes

	// Read in f (from f_c) for this cell
	float f[19];

	// Read f_c from __global to private memory (should be coalesced memory access)
	float rho = 0.0f;
	for (int i = 0; i < 19; i++) {
		f[i] = f_c[ i_1D + i*N_C ];
		rho += f[i];
	}

	float g_x = flpDat->ConstBodyForce[0];
	float g_y = flpDat->ConstBodyForce[1];
	float g_z = flpDat->ConstBodyForce[2];

#ifdef USE_VARIABLE_BODY_FORCE

	// Sum force contributions
	int N_C3 = N_C*3;

	// Try partial sum instead
	for (int p = 0; p < intDat->MaxSurfPointsPerNode; p++) {
		g_x += gfp[i_1D + NC*(3*p)    ];
		g_y += gfp[i_1D + NC*(3*p + 1)];
		g_z += gfp[i_1D + NC*(3*p + 2)];
	}

#endif

	// Compute velocity	(J. Stat. Mech. (2010) P01018 convention)
	// w/ body force contribution (Guo et al. 2002)
	float u_x = (f[1]-f[2]+f[7]+f[8] +f[9] +f[10]-f[11]-f[12]-f[13]-f[14] + 0.5f*g_x)/rho;
	float u_y = (f[3]-f[4]+f[7]-f[8] +f[11]-f[12]+f[15]+f[16]-f[17]-f[18] + 0.5f*g_y)/rho;
	float u_z = (f[5]-f[6]+f[9]-f[10]+f[13]-f[14]+f[15]-f[16]+f[17]-f[18] + 0.5f*g_z)/rho;

	// Write to __global *u
	u[ i_1D         ] = u_x;
	u[ i_1D +   N_C ] = u_y;
	u[ i_1D + 2*N_C ] = u_z;

	// Multiple relaxtion time (BGK) collision
	float f_eq[19], n[19], mn[19], smn[19], msmn[19], mg[19], smg[19], msmg[19]; // Could reduce memory requirement
	equilibirum_distribution_D3Q19(f_eq, rho, u_x, u_y, u_z);

	for(int i = 0; i < 19; i++) {
		n[i] = f_eq[i] - f[i]; // Also gives negative of non-equilibrium part
		//printf("feq,f,n = %f, %f, %f\n", f_eq[i], f[i], n[i]);
	}

	// Guo, Zheng & Shi body force term (2002)
	float fg[19];
	guo_body_force_term(u_x, u_y, u_z, g_x, g_y, g_z, fg);

	// Moments of f_neq and Guo force term
	mn[0] = 0.0; // rho_eq = rho regardless of forcing
	mn[1] = -30.0f*n[0] -11.0f*n[1] -11.0f*n[2] -11.0f*n[3] -11.0f*n[4] -11.0f*n[5] -11.0f*n[6] +8.0f*n[7] +8.0f*n[8] +8.0f*n[9] +8.0f*n[10] +8.0f*n[11] +8.0f*n[12] +8.0f*n[13] +8.0f*n[14] +8.0f*n[15] +8.0f*n[16] +8.0f*n[17] +8.0f*n[18];
	mn[2] = 12.0f*n[0] -4.0f*n[1] -4.0f*n[2] -4.0f*n[3] -4.0f*n[4] -4.0f*n[5] -4.0f*n[6] +n[7] +n[8] +n[9] +n[10] +n[11] +n[12] +n[13] +n[14] +n[15] +n[16] +n[17] +n[18];
	mn[3] = +n[1] -n[2] +n[7] +n[8] +n[9] +n[10] -n[11] -n[12] -n[13] -n[14];
	mn[4] = -4.0f*n[1] +4.0f*n[2] +n[7] +n[8] +n[9] +n[10] -n[11] -n[12] -n[13] -n[14];
	mn[5] = +n[3] -n[4] +n[7] -n[8] +n[11] -n[12] +n[15] +n[16] -n[17] -n[18];
	mn[6] = -4.0f*n[3] +4.0f*n[4] +n[7] -n[8] +n[11] -n[12] +n[15] +n[16] -n[17] -n[18];
	mn[7] = +n[5] -n[6] +n[9] -n[10] +n[13] -n[14] +n[15] -n[16] +n[17] -n[18];
	mn[8] = -4.0f*n[5] +4.0f*n[6] +n[9] -n[10] +n[13] -n[14] +n[15] -n[16] +n[17] -n[18];
	mn[9] = +2.0f*n[1] +2.0f*n[2] -n[3] -n[4] -n[5] -n[6] +n[7] +n[8] +n[9] +n[10] +n[11] +n[12] +n[13] +n[14] -2.0f*n[15] -2.0f*n[16] -2.0f*n[17] -2.0f*n[18];
	mn[10] = -4.0f*n[1] -4.0f*n[2] +2.0f*n[3] +2.0f*n[4] +2.0f*n[5] +2.0f*n[6] +n[7] +n[8] +n[9] +n[10] +n[11] +n[12] +n[13] +n[14] -2.0f*n[15] -2.0f*n[16] -2.0f*n[17] -2.0f*n[18];
	mn[11] = +n[3] +n[4] -n[5] -n[6] +n[7] +n[8] -n[9] -n[10] +n[11] +n[12] -n[13] -n[14];
	mn[12] = -2.0f*n[3] -2.0f*n[4] +2.0f*n[5] +2.0f*n[6] +n[7] +n[8] -n[9] -n[10] +n[11] +n[12] -n[13] -n[14];
	mn[13] = +n[7] -n[8] -n[11] +n[12];
	mn[14] = +n[15] -n[16] -n[17] +n[18];
	mn[15] = +n[9] -n[10] -n[13] +n[14];
	mn[16] = +n[7] +n[8] -n[9] -n[10] -n[11] -n[12] +n[13] +n[14];
	mn[17] = -n[7] +n[8] -n[11] +n[12] +n[15] +n[16] -n[17] -n[18];
	mn[18] = +n[9] -n[10] +n[13] -n[14] -n[15] +n[16] -n[17] +n[18];

	// These expressions for the moments could be simplified
	mg[0] = fg[0] +fg[1] +fg[2] +fg[3] +fg[4] +fg[5] +fg[6] +fg[7] +fg[8] +fg[9] +fg[10] +fg[11] +fg[12] +fg[13] +fg[14] +fg[15] +fg[16] +fg[17] +fg[18];
	mg[1] = -30.0f*fg[0] -11.0f*fg[1] -11.0f*fg[2] -11.0f*fg[3] -11.0f*fg[4] -11.0f*fg[5] -11.0f*fg[6] +8.0f*fg[7] +8.0f*fg[8] +8.0f*fg[9] +8.0f*fg[10] +8.0f*fg[11] +8.0f*fg[12] +8.0f*fg[13] +8.0f*fg[14] +8.0f*fg[15] +8.0f*fg[16] +8.0f*fg[17] +8.0f*fg[18];
	mg[2] = 12.0f*fg[0] -4.0f*fg[1] -4.0f*fg[2] -4.0f*fg[3] -4.0f*fg[4] -4.0f*fg[5] -4.0f*fg[6] +fg[7] +fg[8] +fg[9] +fg[10] +fg[11] +fg[12] +fg[13] +fg[14] +fg[15] +fg[16] +fg[17] +fg[18];
	mg[3] = fg[1] -fg[2] +fg[7] +fg[8] +fg[9] +fg[10] -fg[11] -fg[12] -fg[13] -fg[14];
	mg[4] = -4.0f*fg[1] +4.0f*fg[2] +fg[7] +fg[8] +fg[9] +fg[10] -fg[11] -fg[12] -fg[13] -fg[14];
	mg[5] = fg[3] -fg[4] +fg[7] -fg[8] +fg[11] -fg[12] +fg[15] +fg[16] -fg[17] -fg[18];
	mg[6] = -4.0f*fg[3] +4.0f*fg[4] +fg[7] -fg[8] +fg[11] -fg[12] +fg[15] +fg[16] -fg[17] -fg[18];
	mg[7] = fg[5] -fg[6] +fg[9] -fg[10] +fg[13] -fg[14] +fg[15] -fg[16] +fg[17] -fg[18];
	mg[8] = -4.0f*fg[5] +4.0f*fg[6] +fg[9] -fg[10] +fg[13] -fg[14] +fg[15] -fg[16] +fg[17] -fg[18];
	mg[9] = 2.0f*fg[1] +2.0f*fg[2] -fg[3] -fg[4] -fg[5] -fg[6] +fg[7] +fg[8] +fg[9] +fg[10] +fg[11] +fg[12] +fg[13] +fg[14] -2.0f*fg[15] -2.0f*fg[16] -2.0f*fg[17] -2.0f*fg[18];
	mg[10] = -4.0f*fg[1] -4.0f*fg[2] +2.0f*fg[3] +2.0f*fg[4] +2.0f*fg[5] +2.0f*fg[6] +fg[7] +fg[8] +fg[9] +fg[10] +fg[11] +fg[12] +fg[13] +fg[14] -2.0f*fg[15] -2.0f*fg[16] -2.0f*fg[17] -2.0f*fg[18];
	mg[11] = fg[3] +fg[4] -fg[5] -fg[6] +fg[7] +fg[8] -fg[9] -fg[10] +fg[11] +fg[12] -fg[13] -fg[14];
	mg[12] = -2.0f*fg[3] -2.0f*fg[4] +2.0f*fg[5] +2.0f*fg[6] +fg[7] +fg[8] -fg[9] -fg[10] +fg[11] +fg[12] -fg[13] -fg[14];
	mg[13] = fg[7] -fg[8] -fg[11] +fg[12];
	mg[14] = fg[15] -fg[16] -fg[17] +fg[18];
	mg[15] = fg[9] -fg[10] -fg[13] +fg[14];
	mg[16] = fg[7] +fg[8] -fg[9] -fg[10] -fg[11] -fg[12] +fg[13] +fg[14];
	mg[17] = -fg[7] +fg[8] -fg[11] +fg[12] +fg[15] +fg[16] -fg[17] -fg[18];
	mg[18] = fg[9] -fg[10] +fg[13] -fg[14] -fg[15] +fg[16] -fg[17] +fg[18];

	// Compute relaxation times
	// [8], [9], [10], [14], [15] to be set to 1/tau
	float s[19] = {0.0, 1.19f, 1.40f, 1.0f, 1.20f, 1.0f, 1.20f, 1.0f, 1.0f, 1.0f, 1.0f, 1.20f, 1.40f, 1.40f, 1.0f, 1.0f, 1.98f, 1.98f, 1.98f};
	
#ifdef USE_CONSTANT_VISCOSITY
	float tau = flpDat->NewtonianTau;
	s[8] = 1.0f/tau;  s[9] = 1.0f/tau; s[10] = 1.0f/tau;
	s[14] = 1.0f/tau; s[15] = 1.0f/tau;
#else
	
	// Compute local expression for shear rate tensor, using tau from previous time step
	float tau = tau_p[i_1D];
	
	s[8] = 1.0f/tau;  s[9] = 1.0f/tau; s[10] = 1.0f/tau;
	s[14] = 1.0f/tau; s[15] = 1.0f/tau;
	
	//printf("TAU prev = %f \n", tau);
	
	for(int i = 0; i < 19; i++) {
		smn[i] = s[i]*mn[i]; // MRT relaxation
		smg[i] = s[i]*mg[i]; // Relaxed part of guo term (non-relaxed part added later)
	}
	
	// Convert back
	msmn[0] = 5.2631579E-2f*smn[0] -1.2531328E-2f*smn[1] +4.7619048E-2f*smn[2];
	msmn[1] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] +1.0E-1f*smn[3] -1.0E-1f*smn[4] +5.5555556E-2f*smn[9] -5.5555556E-2f*smn[10];
	msmn[2] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] -1.0E-1f*smn[3] +1.0E-1f*smn[4] +5.5555556E-2f*smn[9] -5.5555556E-2f*smn[10];
	msmn[3] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] +1.0E-1f*smn[5] -1.0E-1f*smn[6] -2.7777778E-2f*smn[9] +2.7777778E-2f*smn[10] +8.3333333E-2f*smn[11] -8.3333333E-2f*smn[12];
	msmn[4] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] -1.0E-1f*smn[5] +1.0E-1f*smn[6] -2.7777778E-2f*smn[9] +2.7777778E-2f*smn[10] +8.3333333E-2f*smn[11] -8.3333333E-2f*smn[12];
	msmn[5] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] +1.0E-1f*smn[7] -1.0E-1f*smn[8] -2.7777778E-2f*smn[9] +2.7777778E-2f*smn[10] -8.3333333E-2f*smn[11] +8.3333333E-2f*smn[12];
	msmn[6] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] -1.0E-1f*smn[7] +1.0E-1f*smn[8] -2.7777778E-2f*smn[9] +2.7777778E-2f*smn[10] -8.3333333E-2f*smn[11] +8.3333333E-2f*smn[12];
	msmn[7] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[3] +2.5E-2f*smn[4] +1.0E-1f*smn[5] +2.5E-2f*smn[6] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] +8.3333333E-2f*smn[11] +4.1666667E-2f*smn[12] +2.5E-1f*smn[13] +1.25E-1f*smn[16] -1.25E-1f*smn[17];
	msmn[8] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[3] +2.5E-2f*smn[4] -1.0E-1f*smn[5] -2.5E-2f*smn[6] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] +8.3333333E-2f*smn[11] +4.1666667E-2f*smn[12] -2.5E-1f*smn[13] +1.25E-1f*smn[16] +1.25E-1f*smn[17];
	msmn[9] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[3] +2.5E-2f*smn[4] +1.0E-1f*smn[7] +2.5E-2f*smn[8] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] -8.3333333E-2f*smn[11] -4.1666667E-2f*smn[12] +2.5E-1f*smn[15] -1.25E-1f*smn[16] +1.25E-1f*smn[18];
	msmn[10] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[3] +2.5E-2f*smn[4] -1.0E-1f*smn[7] -2.5E-2f*smn[8] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] -8.3333333E-2f*smn[11] -4.1666667E-2f*smn[12] -2.5E-1f*smn[15] -1.25E-1f*smn[16] -1.25E-1f*smn[18];
	msmn[11] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[3] -2.5E-2f*smn[4] +1.0E-1f*smn[5] +2.5E-2f*smn[6] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] +8.3333333E-2f*smn[11] +4.1666667E-2f*smn[12] -2.5E-1f*smn[13] -1.25E-1f*smn[16] -1.25E-1f*smn[17];
	msmn[12] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[3] -2.5E-2f*smn[4] -1.0E-1f*smn[5] -2.5E-2f*smn[6] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] +8.3333333E-2f*smn[11] +4.1666667E-2f*smn[12] +2.5E-1f*smn[13] -1.25E-1f*smn[16] +1.25E-1f*smn[17];
	msmn[13] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[3] -2.5E-2f*smn[4] +1.0E-1f*smn[7] +2.5E-2f*smn[8] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] -8.3333333E-2f*smn[11] -4.1666667E-2f*smn[12] -2.5E-1f*smn[15] +1.25E-1f*smn[16] +1.25E-1f*smn[18];
	msmn[14] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[3] -2.5E-2f*smn[4] -1.0E-1f*smn[7] -2.5E-2f*smn[8] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] -8.3333333E-2f*smn[11] -4.1666667E-2f*smn[12] +2.5E-1f*smn[15] +1.25E-1f*smn[16] -1.25E-1f*smn[18];
	msmn[15] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[5] +2.5E-2f*smn[6] +1.0E-1f*smn[7] +2.5E-2f*smn[8] -5.5555556E-2f*smn[9] -2.7777778E-2f*smn[10] +2.5E-1f*smn[14] +1.25E-1f*smn[17] -1.25E-1f*smn[18];
	msmn[16] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[5] +2.5E-2f*smn[6] -1.0E-1f*smn[7] -2.5E-2f*smn[8] -5.5555556E-2f*smn[9] -2.7777778E-2f*smn[10] -2.5E-1f*smn[14] +1.25E-1f*smn[17] +1.25E-1f*smn[18];
	msmn[17] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[5] -2.5E-2f*smn[6] +1.0E-1f*smn[7] +2.5E-2f*smn[8] -5.5555556E-2f*smn[9] -2.7777778E-2f*smn[10] -2.5E-1f*smn[14] -1.25E-1f*smn[17] -1.25E-1f*smn[18];
	msmn[18] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[5] -2.5E-2f*smn[6] -1.0E-1f*smn[7] -2.5E-2f*smn[8] -5.5555556E-2f*smn[9] -2.7777778E-2f*smn[10] +2.5E-1f*smn[14] -1.25E-1f*smn[17] +1.25E-1f*smn[18];
	
	
	// Convert back
	msmg[0] = 5.2631579E-2f*smg[0] -1.2531328E-2f*smg[1] +4.7619048E-2f*smg[2];
	msmg[1] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] +1.0E-1f*smg[3] -1.0E-1f*smg[4] +5.5555556E-2f*smg[9] -5.5555556E-2f*smg[10];
	msmg[2] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] -1.0E-1f*smg[3] +1.0E-1f*smg[4] +5.5555556E-2f*smg[9] -5.5555556E-2f*smg[10];
	msmg[3] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] +1.0E-1f*smg[5] -1.0E-1f*smg[6] -2.7777778E-2f*smg[9] +2.7777778E-2f*smg[10] +8.3333333E-2f*smg[11] -8.3333333E-2f*smg[12];
	msmg[4] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] -1.0E-1f*smg[5] +1.0E-1f*smg[6] -2.7777778E-2f*smg[9] +2.7777778E-2f*smg[10] +8.3333333E-2f*smg[11] -8.3333333E-2f*smg[12];
	msmg[5] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] +1.0E-1f*smg[7] -1.0E-1f*smg[8] -2.7777778E-2f*smg[9] +2.7777778E-2f*smg[10] -8.3333333E-2f*smg[11] +8.3333333E-2f*smg[12];
	msmg[6] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] -1.0E-1f*smg[7] +1.0E-1f*smg[8] -2.7777778E-2f*smg[9] +2.7777778E-2f*smg[10] -8.3333333E-2f*smg[11] +8.3333333E-2f*smg[12];
	msmg[7] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[3] +2.5E-2f*smg[4] +1.0E-1f*smg[5] +2.5E-2f*smg[6] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] +8.3333333E-2f*smg[11] +4.1666667E-2f*smg[12] +2.5E-1f*smg[13] +1.25E-1f*smg[16] -1.25E-1f*smg[17];
	msmg[8] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[3] +2.5E-2f*smg[4] -1.0E-1f*smg[5] -2.5E-2f*smg[6] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] +8.3333333E-2f*smg[11] +4.1666667E-2f*smg[12] -2.5E-1f*smg[13] +1.25E-1f*smg[16] +1.25E-1f*smg[17];
	msmg[9] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[3] +2.5E-2f*smg[4] +1.0E-1f*smg[7] +2.5E-2f*smg[8] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] -8.3333333E-2f*smg[11] -4.1666667E-2f*smg[12] +2.5E-1f*smg[15] -1.25E-1f*smg[16] +1.25E-1f*smg[18];
	msmg[10] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[3] +2.5E-2f*smg[4] -1.0E-1f*smg[7] -2.5E-2f*smg[8] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] -8.3333333E-2f*smg[11] -4.1666667E-2f*smg[12] -2.5E-1f*smg[15] -1.25E-1f*smg[16] -1.25E-1f*smg[18];
	msmg[11] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[3] -2.5E-2f*smg[4] +1.0E-1f*smg[5] +2.5E-2f*smg[6] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] +8.3333333E-2f*smg[11] +4.1666667E-2f*smg[12] -2.5E-1f*smg[13] -1.25E-1f*smg[16] -1.25E-1f*smg[17];
	msmg[12] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[3] -2.5E-2f*smg[4] -1.0E-1f*smg[5] -2.5E-2f*smg[6] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] +8.3333333E-2f*smg[11] +4.1666667E-2f*smg[12] +2.5E-1f*smg[13] -1.25E-1f*smg[16] +1.25E-1f*smg[17];
	msmg[13] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[3] -2.5E-2f*smg[4] +1.0E-1f*smg[7] +2.5E-2f*smg[8] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] -8.3333333E-2f*smg[11] -4.1666667E-2f*smg[12] -2.5E-1f*smg[15] +1.25E-1f*smg[16] +1.25E-1f*smg[18];
	msmg[14] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[3] -2.5E-2f*smg[4] -1.0E-1f*smg[7] -2.5E-2f*smg[8] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] -8.3333333E-2f*smg[11] -4.1666667E-2f*smg[12] +2.5E-1f*smg[15] +1.25E-1f*smg[16] -1.25E-1f*smg[18];
	msmg[15] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[5] +2.5E-2f*smg[6] +1.0E-1f*smg[7] +2.5E-2f*smg[8] -5.5555556E-2f*smg[9] -2.7777778E-2f*smg[10] +2.5E-1f*smg[14] +1.25E-1f*smg[17] -1.25E-1f*smg[18];
	msmg[16] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[5] +2.5E-2f*smg[6] -1.0E-1f*smg[7] -2.5E-2f*smg[8] -5.5555556E-2f*smg[9] -2.7777778E-2f*smg[10] -2.5E-1f*smg[14] +1.25E-1f*smg[17] +1.25E-1f*smg[18];
	msmg[17] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[5] -2.5E-2f*smg[6] +1.0E-1f*smg[7] +2.5E-2f*smg[8] -5.5555556E-2f*smg[9] -2.7777778E-2f*smg[10] -2.5E-1f*smg[14] -1.25E-1f*smg[17] -1.25E-1f*smg[18];
	msmg[18] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[5] -2.5E-2f*smg[6] -1.0E-1f*smg[7] -2.5E-2f*smg[8] -5.5555556E-2f*smg[9] -2.7777778E-2f*smg[10] +2.5E-1f*smg[14] -1.25E-1f*smg[17] +1.25E-1f*smg[18];
	
	float ssum[19];
	for(int i = 0; i < 19; i++) {
		ssum[i] = msmn[i] + fg[i] - 0.5f*msmg[i];
	}
	
	// Shear rate tensor without prefactor, see Chai and Zhao, PRE 86, 016705 (2012)
	float scc[3][3];

	scc[0][0] = ssum[1] +ssum[2] +ssum[7] +ssum[8] +ssum[9] +ssum[10] +ssum[11] +ssum[12] +ssum[13] +ssum[14];
	scc[0][1] = ssum[7] -ssum[8] -ssum[11] +ssum[12];
	scc[0][2] = ssum[9] -ssum[10] -ssum[13] +ssum[14];
	scc[1][0] = scc[0][1];
	scc[1][1] = ssum[3] +ssum[4] +ssum[7] +ssum[8] +ssum[11] +ssum[12] +ssum[15] +ssum[16] +ssum[17] +ssum[18];
	scc[1][2] = ssum[15] -ssum[16] -ssum[17] +ssum[18];
	scc[2][0] = scc[0][2];
	scc[2][1] = scc[1][2];
	scc[2][2] = ssum[5] +ssum[6] +ssum[9] +ssum[10] +ssum[13] +ssum[14] +ssum[15] +ssum[16] +ssum[17] +ssum[18];
	
	// -(uF + Fu) term  
	scc[0][0] -= 2*u_x*g_x;
	scc[0][1] -= (u_x*g_y + u_y*g_x);
	scc[0][2] -= (u_x*g_z + u_z*g_x);
	scc[1][0] -= (u_y*g_x + u_x*g_y);
	scc[1][1] -= 2*u_y*g_y;
	scc[1][2] -= (u_y*g_z + u_z*g_y);
	scc[2][0] -= (u_z*g_x + u_x*g_z);
	scc[2][1] -= (u_z*g_y + u_y*g_z);
	scc[2][2] -= 2*u_z*g_z; 

	float traceTerm = n[1] +n[2] +n[3] +n[4] +n[5] +n[6] +2.0f*n[7] +2.0f*n[8] +2.0f*n[9] +2.0f*n[10] +2.0f*n[11] +2.0f*n[12] +2.0f*n[13] +2.0f*n[14] +2.0f*n[15] +2.0f*n[16] +2.0f*n[17] +2.0f*n[18];
	scc[1][1] -= traceTerm/3.0f;
	scc[2][2] -= traceTerm/3.0f;
	scc[3][3] -= traceTerm/3.0f;

	// Shear rate invariant
	float srtII = 0.0;
	for(int i = 0; i < 3; i++) {
		for(int j = 0; j < 3; j++) {
			srtII += scc[i][j]*scc[i][j];
		}
	}
	// 2.1213203 comes from sqrt(2*1.5^2)
	srtII = sqrt(srtII)*2.1213203/rho;
	//printf("srtII = %f\n", srtII);

	// Tau redefinition for this time step
	tau = compute_tau(srtII, &(flpDat->ViscosityParams[0]));
	tau_p[i_1D] = tau;

#endif // Tau computation

	// Recalcualate s
	s[8] = 1.0f/tau;  s[9] = 1.0f/tau; s[10] = 1.0f/tau;
	s[14] = 1.0f/tau; s[15] = 1.0f/tau;
	
	for(int i = 0; i < 19; i++) {
		smn[i] = s[i]*mn[i]; // MRT relaxation
		smg[i] = s[i]*mg[i]; // Relaxed part of guo term (non-relaxed part added later)
	}
	
	// Convert back
	msmn[0] = 5.2631579E-2f*smn[0] -1.2531328E-2f*smn[1] +4.7619048E-2f*smn[2];
	msmn[1] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] +1.0E-1f*smn[3] -1.0E-1f*smn[4] +5.5555556E-2f*smn[9] -5.5555556E-2f*smn[10];
	msmn[2] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] -1.0E-1f*smn[3] +1.0E-1f*smn[4] +5.5555556E-2f*smn[9] -5.5555556E-2f*smn[10];
	msmn[3] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] +1.0E-1f*smn[5] -1.0E-1f*smn[6] -2.7777778E-2f*smn[9] +2.7777778E-2f*smn[10] +8.3333333E-2f*smn[11] -8.3333333E-2f*smn[12];
	msmn[4] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] -1.0E-1f*smn[5] +1.0E-1f*smn[6] -2.7777778E-2f*smn[9] +2.7777778E-2f*smn[10] +8.3333333E-2f*smn[11] -8.3333333E-2f*smn[12];
	msmn[5] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] +1.0E-1f*smn[7] -1.0E-1f*smn[8] -2.7777778E-2f*smn[9] +2.7777778E-2f*smn[10] -8.3333333E-2f*smn[11] +8.3333333E-2f*smn[12];
	msmn[6] = 5.2631579E-2f*smn[0] -4.5948204E-3f*smn[1] -1.5873016E-2f*smn[2] -1.0E-1f*smn[7] +1.0E-1f*smn[8] -2.7777778E-2f*smn[9] +2.7777778E-2f*smn[10] -8.3333333E-2f*smn[11] +8.3333333E-2f*smn[12];
	msmn[7] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[3] +2.5E-2f*smn[4] +1.0E-1f*smn[5] +2.5E-2f*smn[6] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] +8.3333333E-2f*smn[11] +4.1666667E-2f*smn[12] +2.5E-1f*smn[13] +1.25E-1f*smn[16] -1.25E-1f*smn[17];
	msmn[8] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[3] +2.5E-2f*smn[4] -1.0E-1f*smn[5] -2.5E-2f*smn[6] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] +8.3333333E-2f*smn[11] +4.1666667E-2f*smn[12] -2.5E-1f*smn[13] +1.25E-1f*smn[16] +1.25E-1f*smn[17];
	msmn[9] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[3] +2.5E-2f*smn[4] +1.0E-1f*smn[7] +2.5E-2f*smn[8] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] -8.3333333E-2f*smn[11] -4.1666667E-2f*smn[12] +2.5E-1f*smn[15] -1.25E-1f*smn[16] +1.25E-1f*smn[18];
	msmn[10] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[3] +2.5E-2f*smn[4] -1.0E-1f*smn[7] -2.5E-2f*smn[8] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] -8.3333333E-2f*smn[11] -4.1666667E-2f*smn[12] -2.5E-1f*smn[15] -1.25E-1f*smn[16] -1.25E-1f*smn[18];
	msmn[11] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[3] -2.5E-2f*smn[4] +1.0E-1f*smn[5] +2.5E-2f*smn[6] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] +8.3333333E-2f*smn[11] +4.1666667E-2f*smn[12] -2.5E-1f*smn[13] -1.25E-1f*smn[16] -1.25E-1f*smn[17];
	msmn[12] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[3] -2.5E-2f*smn[4] -1.0E-1f*smn[5] -2.5E-2f*smn[6] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] +8.3333333E-2f*smn[11] +4.1666667E-2f*smn[12] +2.5E-1f*smn[13] -1.25E-1f*smn[16] +1.25E-1f*smn[17];
	msmn[13] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[3] -2.5E-2f*smn[4] +1.0E-1f*smn[7] +2.5E-2f*smn[8] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] -8.3333333E-2f*smn[11] -4.1666667E-2f*smn[12] -2.5E-1f*smn[15] +1.25E-1f*smn[16] +1.25E-1f*smn[18];
	msmn[14] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[3] -2.5E-2f*smn[4] -1.0E-1f*smn[7] -2.5E-2f*smn[8] +2.7777778E-2f*smn[9] +1.3888889E-2f*smn[10] -8.3333333E-2f*smn[11] -4.1666667E-2f*smn[12] +2.5E-1f*smn[15] +1.25E-1f*smn[16] -1.25E-1f*smn[18];
	msmn[15] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[5] +2.5E-2f*smn[6] +1.0E-1f*smn[7] +2.5E-2f*smn[8] -5.5555556E-2f*smn[9] -2.7777778E-2f*smn[10] +2.5E-1f*smn[14] +1.25E-1f*smn[17] -1.25E-1f*smn[18];
	msmn[16] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] +1.0E-1f*smn[5] +2.5E-2f*smn[6] -1.0E-1f*smn[7] -2.5E-2f*smn[8] -5.5555556E-2f*smn[9] -2.7777778E-2f*smn[10] -2.5E-1f*smn[14] +1.25E-1f*smn[17] +1.25E-1f*smn[18];
	msmn[17] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[5] -2.5E-2f*smn[6] +1.0E-1f*smn[7] +2.5E-2f*smn[8] -5.5555556E-2f*smn[9] -2.7777778E-2f*smn[10] -2.5E-1f*smn[14] -1.25E-1f*smn[17] -1.25E-1f*smn[18];
	msmn[18] = 5.2631579E-2f*smn[0] +3.3416876E-3f*smn[1] +3.9682540E-3f*smn[2] -1.0E-1f*smn[5] -2.5E-2f*smn[6] -1.0E-1f*smn[7] -2.5E-2f*smn[8] -5.5555556E-2f*smn[9] -2.7777778E-2f*smn[10] +2.5E-1f*smn[14] -1.25E-1f*smn[17] +1.25E-1f*smn[18];
	
	
	// Convert back
	msmg[0] = 5.2631579E-2f*smg[0] -1.2531328E-2f*smg[1] +4.7619048E-2f*smg[2];
	msmg[1] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] +1.0E-1f*smg[3] -1.0E-1f*smg[4] +5.5555556E-2f*smg[9] -5.5555556E-2f*smg[10];
	msmg[2] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] -1.0E-1f*smg[3] +1.0E-1f*smg[4] +5.5555556E-2f*smg[9] -5.5555556E-2f*smg[10];
	msmg[3] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] +1.0E-1f*smg[5] -1.0E-1f*smg[6] -2.7777778E-2f*smg[9] +2.7777778E-2f*smg[10] +8.3333333E-2f*smg[11] -8.3333333E-2f*smg[12];
	msmg[4] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] -1.0E-1f*smg[5] +1.0E-1f*smg[6] -2.7777778E-2f*smg[9] +2.7777778E-2f*smg[10] +8.3333333E-2f*smg[11] -8.3333333E-2f*smg[12];
	msmg[5] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] +1.0E-1f*smg[7] -1.0E-1f*smg[8] -2.7777778E-2f*smg[9] +2.7777778E-2f*smg[10] -8.3333333E-2f*smg[11] +8.3333333E-2f*smg[12];
	msmg[6] = 5.2631579E-2f*smg[0] -4.5948204E-3f*smg[1] -1.5873016E-2f*smg[2] -1.0E-1f*smg[7] +1.0E-1f*smg[8] -2.7777778E-2f*smg[9] +2.7777778E-2f*smg[10] -8.3333333E-2f*smg[11] +8.3333333E-2f*smg[12];
	msmg[7] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[3] +2.5E-2f*smg[4] +1.0E-1f*smg[5] +2.5E-2f*smg[6] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] +8.3333333E-2f*smg[11] +4.1666667E-2f*smg[12] +2.5E-1f*smg[13] +1.25E-1f*smg[16] -1.25E-1f*smg[17];
	msmg[8] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[3] +2.5E-2f*smg[4] -1.0E-1f*smg[5] -2.5E-2f*smg[6] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] +8.3333333E-2f*smg[11] +4.1666667E-2f*smg[12] -2.5E-1f*smg[13] +1.25E-1f*smg[16] +1.25E-1f*smg[17];
	msmg[9] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[3] +2.5E-2f*smg[4] +1.0E-1f*smg[7] +2.5E-2f*smg[8] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] -8.3333333E-2f*smg[11] -4.1666667E-2f*smg[12] +2.5E-1f*smg[15] -1.25E-1f*smg[16] +1.25E-1f*smg[18];
	msmg[10] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[3] +2.5E-2f*smg[4] -1.0E-1f*smg[7] -2.5E-2f*smg[8] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] -8.3333333E-2f*smg[11] -4.1666667E-2f*smg[12] -2.5E-1f*smg[15] -1.25E-1f*smg[16] -1.25E-1f*smg[18];
	msmg[11] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[3] -2.5E-2f*smg[4] +1.0E-1f*smg[5] +2.5E-2f*smg[6] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] +8.3333333E-2f*smg[11] +4.1666667E-2f*smg[12] -2.5E-1f*smg[13] -1.25E-1f*smg[16] -1.25E-1f*smg[17];
	msmg[12] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[3] -2.5E-2f*smg[4] -1.0E-1f*smg[5] -2.5E-2f*smg[6] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] +8.3333333E-2f*smg[11] +4.1666667E-2f*smg[12] +2.5E-1f*smg[13] -1.25E-1f*smg[16] +1.25E-1f*smg[17];
	msmg[13] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[3] -2.5E-2f*smg[4] +1.0E-1f*smg[7] +2.5E-2f*smg[8] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] -8.3333333E-2f*smg[11] -4.1666667E-2f*smg[12] -2.5E-1f*smg[15] +1.25E-1f*smg[16] +1.25E-1f*smg[18];
	msmg[14] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[3] -2.5E-2f*smg[4] -1.0E-1f*smg[7] -2.5E-2f*smg[8] +2.7777778E-2f*smg[9] +1.3888889E-2f*smg[10] -8.3333333E-2f*smg[11] -4.1666667E-2f*smg[12] +2.5E-1f*smg[15] +1.25E-1f*smg[16] -1.25E-1f*smg[18];
	msmg[15] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[5] +2.5E-2f*smg[6] +1.0E-1f*smg[7] +2.5E-2f*smg[8] -5.5555556E-2f*smg[9] -2.7777778E-2f*smg[10] +2.5E-1f*smg[14] +1.25E-1f*smg[17] -1.25E-1f*smg[18];
	msmg[16] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] +1.0E-1f*smg[5] +2.5E-2f*smg[6] -1.0E-1f*smg[7] -2.5E-2f*smg[8] -5.5555556E-2f*smg[9] -2.7777778E-2f*smg[10] -2.5E-1f*smg[14] +1.25E-1f*smg[17] +1.25E-1f*smg[18];
	msmg[17] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[5] -2.5E-2f*smg[6] +1.0E-1f*smg[7] +2.5E-2f*smg[8] -5.5555556E-2f*smg[9] -2.7777778E-2f*smg[10] -2.5E-1f*smg[14] -1.25E-1f*smg[17] -1.25E-1f*smg[18];
	msmg[18] = 5.2631579E-2f*smg[0] +3.3416876E-3f*smg[1] +3.9682540E-3f*smg[2] -1.0E-1f*smg[5] -2.5E-2f*smg[6] -1.0E-1f*smg[7] -2.5E-2f*smg[8] -5.5555556E-2f*smg[9] -2.7777778E-2f*smg[10] +2.5E-1f*smg[14] -1.25E-1f*smg[17] +1.25E-1f*smg[18];

	int streamIndex[19];
	stream_locations(N_x, N_y, N_z, i_x, i_y, i_z, streamIndex);

	// Propagate to f_s (not taking into account boundary conditions)
	for (int i=0; i<19; i++) {
		f_s[streamIndex[i]] = f[i] + msmn[i] + fg[i] - 0.5f*msmg[i]; // fg contains non-relaxed part of full Guo term
		//printf("i, f, msmn, fg, 0.5f*msmg; %d %f %f %f %f \n", i, f[i], msmn[i], fg[i], 0.5f*msmg[i]);
	}
}

__kernel void boundary_periodic(__global float* f_s,
	__global int_param_struct* intDat,
	__global int* streamMapping)
{
	int i_k = get_global_id(0);
	int N_BC = get_global_size(0); // Total number of periodic boundary nodes

	int i_1D = streamMapping[i_k];
	int typeBC = streamMapping[i_k + N_BC];

	// Uppercase N to denote total lattice size (including buffer layer)
	int N[3];
	N[0] = intDat->LatticeSize[0];
	N[1] = intDat->LatticeSize[1];
	N[2] = intDat->LatticeSize[2];
	int N_C = N[0]*N[1]*N[2];

	// D3Q19 version

	// Indexes of unknown f for each type of boundary node
	// First col specifies amount of unknows
	int unknowns[26][13] = {
	// 6 faces, each 5 unknown components
		{ 5, 1, 7, 8, 9,10, 0, 0, 0, 0, 0, 0, 0}, // x- 0
		{ 5, 2,11,12,13,14, 0, 0, 0, 0, 0, 0, 0}, // x+ 1
		{ 5, 3, 7,11,15,16, 0, 0, 0, 0, 0, 0, 0}, // y- 2
		{ 5, 4, 8,12,17,18, 0, 0, 0, 0, 0, 0, 0}, // y+ 3
		{ 5, 5, 9,13,15,17, 0, 0, 0, 0, 0, 0, 0}, // z- 4
		{ 5, 6,10,14,16,18, 0, 0, 0, 0, 0, 0, 0}, // z+ 5
	// 12 edges, each 9 unknown components
		{ 9, 1, 3, 7, 8, 9,10,11,15,16, 0, 0, 0}, // x-y- 6
		{ 9, 1, 4, 7, 8, 9,10,12,17,18, 0, 0, 0}, // x-y+ 7
		{ 9, 1, 5, 7, 8, 9,10,13,15,17, 0, 0, 0}, // x-z- 8
		{ 9, 1, 6, 7, 8, 9,10,14,16,18, 0, 0, 0}, // x-z+ 9
		{ 9, 2, 3, 7,11,12,13,14,15,16, 0, 0, 0}, // x+y- 10
		{ 9, 2, 4, 8,11,12,13,14,17,18, 0, 0, 0}, // x+y+ 11
		{ 9, 2, 5, 9,11,12,13,14,15,17, 0, 0, 0}, // x+z- 12
		{ 9, 2, 6,10,11,12,13,14,16,18, 0, 0, 0}, // x+z+ 13
		{ 9, 3, 5, 7, 9,11,13,15,16,17, 0, 0, 0}, // y-z- 14
		{ 9, 3, 6, 7,10,11,14,15,16,18, 0, 0, 0}, // y-z+ 15
		{ 9, 4, 5, 8, 9,12,13,15,17,18, 0, 0, 0}, // y+z- 16
		{ 9, 4, 6, 8,10,12,14,16,17,18, 0, 0, 0}, // y+z+ 17
	// 8 vertices, each 12 unknown components
		{ 12, 1, 3, 5, 7, 8, 9,10,11,13,15,16,17}, // x-y-z- 18
		{ 12, 1, 3, 6, 7, 8, 9,10,11,14,15,16,18}, // x-y-z+ 19
		{ 12, 1, 4, 5, 7, 8, 9,10,12,13,15,17,18}, // x-y+z- 20
		{ 12, 1, 4, 6, 7, 8, 9,10,12,14,16,17,18}, // x-y+z+ 21
		{ 12, 2, 3, 5, 7, 9,11,12,13,14,15,16,17}, // x+y-z- 22
		{ 12, 2, 3, 6, 7,10,11,12,13,14,15,16,18}, // x+y-z+ 23
		{ 12, 2, 4, 5, 8, 9,11,12,13,14,15,17,18}, // x+y+z- 24
		{ 12, 2, 4, 6, 8,10,11,12,13,14,16,17,18}  // x+y+z+ 25
	};

	// Specifies whether node has a face on x/y/z boundary, and sign of its inward normal
	int inwardNormals[26][3] = {
		{ 1, 0, 0}, // has face where x-axis points inwards
		{-1, 0, 0}, // x-axis points outwards
		{ 0, 1, 0},
		{ 0,-1, 0},
		{ 0, 0, 1},
		{ 0, 0,-1},

		{ 1, 1, 0}, // edge where x and y axis point inwards
		{ 1,-1, 0},
		{ 1, 0, 1},
		{ 1, 0,-1},
		{-1, 1, 0},
		{-1,-1, 0},
		{-1, 0, 1},
		{-1, 0,-1},
		{ 0, 1, 1},
		{ 0, 1,-1},
		{ 0,-1, 1},
		{ 0,-1,-1},

		{ 1, 1, 1},
		{ 1, 1,-1},
		{ 1,-1, 1},
		{ 1,-1,-1},
		{-1, 1, 1},
		{-1, 1,-1},
		{-1,-1, 1},
		{-1,-1,-1}
	};

	int numUnknowns = unknowns[typeBC][0];

	// Loop over unknowns
	for (int u=0; u<numUnknowns; u++)
	{
		int i_f = unknowns[typeBC][u+1];

		int offset[3];
		// If component of c and inward normals are both non-zero and have same direction,
		// then we need to get this component from the periodic image in that direction.
		for (int dim=0; dim<3; dim++) {
			int c_a = intDat->BasisVel[i_f][dim];
			int m_a = inwardNormals[typeBC][dim];
			// If both non-zero and same direction
			offset[dim] = ((c_a*m_a*(c_a+m_a))/2)*(N[dim]-2);
		}
		//printf("i_k,typeBC,i,i_f,offset %d,%d,%d,%d %d,%d,%d\n",
		//i_k, typeBC, i_1D, i_f, offset[0], offset[1], offset[2]);

		int periodic_1D = i_1D + offset[0] + N[0]*(offset[1] + N[1]*offset[2]);

		// Read component i_f from periodic-offset cell, and write to this one
		f_s[i_f*N_C + i_1D] = f_s[i_f*N_C + periodic_1D];
	}
}

__kernel void boundary_velocity(
	__global float* f_s,
	__global int_param_struct* intDat,
	__global flp_param_struct* flpDat,
	int wallAxis) // Could try adding this argument to intDat
{
	
	// Get 3D indices
	int i_3[3]; // Needs to be an array
	i_3[0] = get_global_id(0); // Using global_work_offset = {1,1,1}
	i_3[1] = get_global_id(1);
	i_3[2] = get_global_id(2);
	int i_lu = get_global_id(wallAxis)-1; //  0 or 1 for lower or upper wall
	int i_lu_pm = i_lu*2 - 1;             // -1 or 1 for lower or upper wall

	int N[3];
	N[0] = intDat->LatticeSize[0];
	N[1] = intDat->LatticeSize[1];
	N[2] = intDat->LatticeSize[2];
	int N_C = N[0]*N[1]*N[2];

	// Wall index (-x,+x, -y,+y, -z,+z) numbered from 0 to 5
	int i_w = wallAxis*2 + i_lu; // -1 because of work_offset

	// Eqivalent index for entire lattice (1->1, 2->n-2)
	i_3[wallAxis] += (i_3[wallAxis]-1)*(N[wallAxis]-4);
	int i_1D = i_3[0] + N[0]*(i_3[1] + N[1]*i_3[2]);

	// Tabulated velocity boundary condition
	// 5 unknowns and 14 knowns in a symmetric order (see thesis)
	int tabUn[6][5] = {
		{1, 7, 8, 9,10}, // x- wall
		{2,11,12,13,14}, // x+ wall
		{3, 7,11,15,16}, // y- wall
		{4, 8,12,17,18}, // y+ wall
		{5, 9,13,15,17}, // z- wall
		{6,10,14,16,18}  // z+ wall
	};

	int tabKn[6][14] = {
		{0, 3, 4, 5, 6,15,16,17,18, 2,11,12,13,14},
		{0, 3, 4, 5, 6,15,16,17,18, 1, 7, 8, 9,10},
		{0, 1, 2, 5, 6, 9,10,13,14, 4, 8,12,17,18},
		{0, 1, 2, 5, 6, 9,10,13,14, 3, 7,11,15,16},
		{0, 1, 2, 3, 4, 7, 8,11,12, 6,10,14,16,18},
		{0, 1, 2, 3, 4, 7, 8,11,12, 5, 9,13,15,17}
	};

	int tabAxes[6][3] = {
		//n a1 a2
		{0, 1, 2},
		{0, 1, 2},
		{1, 0, 2},
		{1, 0, 2},
		{2, 0, 1},
		{2, 0, 1},
	};

	// Read in 14 knowns
	float f_k[14];
	for (int i_k=0; i_k<14; i_k++) {
		f_k[i_k] = f_s[ i_1D + tabKn[i_w][i_k]*N_C ];
	}

	// Read in velocities
	float u_w[6];
	u_w[0] = flpDat->VelLower[0]; // Only really need 3 of these
	u_w[1] = flpDat->VelLower[1];
	u_w[2] = flpDat->VelLower[2];
	u_w[3] = flpDat->VelUpper[0];
	u_w[4] = flpDat->VelUpper[1];
	u_w[5] = flpDat->VelUpper[2];

	float u[3]; // Velocity for this node
	u[0] = u_w[i_lu*3    ];
	u[1] = u_w[i_lu*3 + 1];
	u[2] = u_w[i_lu*3 + 2];

	float u_n = -i_lu_pm*u[tabAxes[i_w][0]]; // Inwards normal fluid velocity
	float u_a1 = u[tabAxes[i_w][1]]; // Tangential velocity axis 1
	float u_a2 = u[tabAxes[i_w][2]]; // Tangential velocity axis 2

	// Calculate rho
	float rho = ( f_k[0]+f_k[1]+f_k[2]+f_k[3]+f_k[4]+f_k[5]+f_k[6]+f_k[7]+f_k[8]
		+ 2*(f_k[9]+f_k[10]+f_k[11]+f_k[12]+f_k[13]) )/(1.0f-u_n);

	// Calculate 'tranverse momentum correction'
	float N_a1 = 0.5f*(f_k[1]+f_k[5]+f_k[6] -f_k[2]-f_k[7]-f_k[8]) - rho*u_a1/3.0f;
	float N_a2 = 0.5f*(f_k[3]+f_k[5]+f_k[7] -f_k[4]-f_k[6]-f_k[8]) - rho*u_a2/3.0f;

	// Calculate unknown normal to wall, write to f_s for this node
	f_s[ i_1D + tabUn[i_w][0]*N_C ] = f_k[9] + rho*u_n/3.0f;

	// Other four unknowns
	f_s[ i_1D + tabUn[i_w][1]*N_C ] = f_k[11] + rho*(u_n + u_a1)/6.0f - N_a1;
	f_s[ i_1D + tabUn[i_w][2]*N_C ] = f_k[10] + rho*(u_n - u_a1)/6.0f + N_a1;
	f_s[ i_1D + tabUn[i_w][3]*N_C ] = f_k[13] + rho*(u_n + u_a2)/6.0f - N_a2;
	f_s[ i_1D + tabUn[i_w][4]*N_C ] = f_k[12] + rho*(u_n - u_a2)/6.0f + N_a2;
}


__kernel void collideSRT_newtonian_stream_D3Q19(
	__global float* f_c,
	__global float* f_s,
	__global float* g,
	__global float* u,
	__global int_param_struct* intDat,
	__global flp_param_struct* flpDat)
{
	// Get 3D indices
	int i_x = get_global_id(0); // Using global_work_offset to take buffer layer into account
	int i_y = get_global_id(1);
	int i_z = get_global_id(2);

	// Convention: upper-case N for total lattice array size (including buffer)
	int N_x = intDat->LatticeSize[0];
	int N_y = intDat->LatticeSize[1];
	int N_z = intDat->LatticeSize[2];

	// 1D index
	int i_1D = i_x + N_x*(i_y + N_y*i_z);
	int N_C = N_x*N_y*N_z; // Total nodes

	// Read in f (from f_c) for this cell
	float f[19];

	// Read f_c from __global to private memory (should be coalesced memory access)
	float rho = 0.0f;
	for (int i=0; i<19; i++) {
		f[i] = f_c[ i_1D + i*N_C ];
		rho += f[i];
	}

#ifdef USE_CONSTANT_BODY_FORCE
	float g_x = flpDat->ConstBodyForce[0];
	float g_y = flpDat->ConstBodyForce[1];
	float g_z = flpDat->ConstBodyForce[2];
#else
	float g_x = g[ i_1D         ];
	float g_y = g[ i_1D +   N_C ];
	float g_z = g[ i_1D + 2*N_C ];
#endif

	// Compute velocity	(J. Stat. Mech. (2010) P01018 convention)
	// w/ body force contribution (Guo et al. 2002)
	float u_x = (f[1]-f[2]+f[7]+f[8] +f[9] +f[10]-f[11]-f[12]-f[13]-f[14] + 0.5f*g_x)/rho;
	float u_y = (f[3]-f[4]+f[7]-f[8] +f[11]-f[12]+f[15]+f[16]-f[17]-f[18] + 0.5f*g_y)/rho;
	float u_z = (f[5]-f[6]+f[9]-f[10]+f[13]-f[14]+f[15]-f[16]+f[17]-f[18] + 0.5f*g_z)/rho;

	// Write to __global *u
	u[ i_1D         ] = u_x;
	u[ i_1D +   N_C ] = u_y;
	u[ i_1D + 2*N_C ] = u_z;

	// Single relaxtion time (BGK) collision
	float f_eq[19];
	equilibirum_distribution_D3Q19(f_eq, rho, u_x, u_y, u_z);

	int streamIndex[19];
	stream_locations(N_x, N_y, N_z, i_x, i_y, i_z, streamIndex);

	// Guo, Zheng & Shi body force term (2002)
	float tau = flpDat->NewtonianTau;
	float fGuo[19];
	guo_body_force_term(u_x, u_y, u_z, g_x, g_y, g_z, fGuo);

	float pfGuo = (1.0f - 0.5f/tau); // Guo term SRT collision prefactor

	//float guoSum = 0.0;
	for(int i = 0; i < 19; i++) {
		fGuo[i] *= pfGuo;
		//guoSum += fGuo[i];
		//printf("Guo, guosum %d %e %e\n", i, fGuo[i], guoSum);
	}

	// Propagate to f_s (not taking into account boundary conditions)
	for (int i=0; i<19; i++) {
		f_s[streamIndex[i]] = f[i] + (f_eq[i]-f[i])/tau + fGuo[i];
	}

}


// Helper functions
void stream_locations(int N_x, int N_y, int N_z, int i_x, int i_y, int i_z, int* index)
{
	int i_1D = i_x + N_x*(i_y + N_y*i_z);
	int N_xy = N_x*N_y;
	int N_C = N_xy*N_z;

	index[0]  =          i_1D;
	index[1]  =    N_C + i_1D + 1;
	index[2]  =  2*N_C + i_1D - 1;
	index[3]  =  3*N_C + i_1D     + N_x;
	index[4]  =  4*N_C + i_1D     - N_x;
	index[5]  =  5*N_C + i_1D           + N_xy;
	index[6]  =  6*N_C + i_1D           - N_xy;
	index[7]  =  7*N_C + i_1D + 1 + N_x;
	index[8]  =  8*N_C + i_1D + 1 - N_x;
	index[9]  =  9*N_C + i_1D + 1       + N_xy;
	index[10] = 10*N_C + i_1D + 1       - N_xy;
	index[11] = 11*N_C + i_1D - 1 + N_x;
	index[12] = 12*N_C + i_1D - 1 - N_x;
	index[13] = 13*N_C + i_1D - 1       + N_xy;
	index[14] = 14*N_C + i_1D - 1       - N_xy;
	index[15] = 15*N_C + i_1D     + N_x + N_xy;
	index[16] = 16*N_C + i_1D     + N_x - N_xy;
	index[17] = 17*N_C + i_1D     - N_x + N_xy;
	index[18] = 18*N_C + i_1D     - N_x - N_xy;
}

void equilibirum_distribution_D3Q19(float* f_eq, float rho, float u_x, float u_y, float u_z)
{
	float u_sq = u_x*u_x + u_y*u_y + u_z*u_z;

	f_eq[0] = (rho/3.0f)*(1.0f - 1.5f*u_sq);

	// could remove factor of 1.5
	f_eq[1]  = (rho/18.0f)*(1.0f + 3.0f*u_x + 4.5f*u_x*u_x - 1.5f*u_sq);
	f_eq[2]  = (rho/18.0f)*(1.0f - 3.0f*u_x + 4.5f*u_x*u_x - 1.5f*u_sq);
	f_eq[3]  = (rho/18.0f)*(1.0f + 3.0f*u_y + 4.5f*u_y*u_y - 1.5f*u_sq);
	f_eq[4]  = (rho/18.0f)*(1.0f - 3.0f*u_y + 4.5f*u_y*u_y - 1.5f*u_sq);
	f_eq[5]  = (rho/18.0f)*(1.0f + 3.0f*u_z + 4.5f*u_z*u_z - 1.5f*u_sq);
	f_eq[6]  = (rho/18.0f)*(1.0f - 3.0f*u_z + 4.5f*u_z*u_z - 1.5f*u_sq);

	f_eq[7]  = (rho/36.0f)*(1.0f + 3.0f*(u_x+u_y) + 4.5f*(u_x+u_y)*(u_x+u_y) - 1.5f*u_sq);
	f_eq[8]  = (rho/36.0f)*(1.0f + 3.0f*(u_x-u_y) + 4.5f*(u_x-u_y)*(u_x-u_y) - 1.5f*u_sq);
	f_eq[9]  = (rho/36.0f)*(1.0f + 3.0f*(u_x+u_z) + 4.5f*(u_x+u_z)*(u_x+u_z) - 1.5f*u_sq);
	f_eq[10] = (rho/36.0f)*(1.0f + 3.0f*(u_x-u_z) + 4.5f*(u_x-u_z)*(u_x-u_z) - 1.5f*u_sq);

	f_eq[11] = (rho/36.0f)*(1.0f + 3.0f*(-u_x+u_y) + 4.5f*(-u_x+u_y)*(-u_x+u_y) - 1.5f*u_sq);
	f_eq[12] = (rho/36.0f)*(1.0f + 3.0f*(-u_x-u_y) + 4.5f*(-u_x-u_y)*(-u_x-u_y) - 1.5f*u_sq);
	f_eq[13] = (rho/36.0f)*(1.0f + 3.0f*(-u_x+u_z) + 4.5f*(-u_x+u_z)*(-u_x+u_z) - 1.5f*u_sq);
	f_eq[14] = (rho/36.0f)*(1.0f + 3.0f*(-u_x-u_z) + 4.5f*(-u_x-u_z)*(-u_x-u_z) - 1.5f*u_sq);

	f_eq[15] = (rho/36.0f)*(1.0f + 3.0f*(u_y+u_z) + 4.5f*(u_y+u_z)*(u_y+u_z) - 1.5f*u_sq);
	f_eq[16] = (rho/36.0f)*(1.0f + 3.0f*(u_y-u_z) + 4.5f*(u_y-u_z)*(u_y-u_z) - 1.5f*u_sq);
	f_eq[17] = (rho/36.0f)*(1.0f + 3.0f*(-u_y+u_z) + 4.5f*(-u_y+u_z)*(-u_y+u_z) - 1.5f*u_sq);
	f_eq[18] = (rho/36.0f)*(1.0f + 3.0f*(-u_y-u_z) + 4.5f*(-u_y-u_z)*(-u_y-u_z) - 1.5f*u_sq);

}

// Guo body force term before any relaxation factor applied
void guo_body_force_term(float u_x, float u_y, float u_z,
	float g_x, float g_y, float g_z, float* fGuo)
{
	float uDg = u_x*g_x + u_y*g_y + u_z*g_z;

	fGuo[0 ] = -uDg;
	fGuo[1 ] = ( g_x - uDg + 3.0f*u_x*g_x )/6.0f; // Factor of 3 cancelled
	fGuo[2 ] = (-g_x - uDg + 3.0f*u_x*g_x )/6.0f;
	fGuo[3 ] = ( g_y - uDg + 3.0f*u_y*g_y )/6.0f;
	fGuo[4 ] = (-g_y - uDg + 3.0f*u_y*g_y )/6.0f;
	fGuo[5 ] = ( g_z - uDg + 3.0f*u_z*g_z )/6.0f;
	fGuo[6 ] = (-g_z - uDg + 3.0f*u_z*g_z )/6.0f;

	fGuo[7 ] = ( g_x+g_y - uDg + 3.0f*( u_x+u_y)*( g_x+g_y) )/12.0f;
	fGuo[8 ] = ( g_x-g_y - uDg + 3.0f*( u_x-u_y)*( g_x-g_y) )/12.0f;
	fGuo[9 ] = ( g_x+g_z - uDg + 3.0f*( u_x+u_z)*( g_x+g_z) )/12.0f;
	fGuo[10] = ( g_x-g_z - uDg + 3.0f*( u_x-u_z)*( g_x-g_z) )/12.0f;

	fGuo[11] = (-g_x+g_y - uDg + 3.0f*(-u_x+u_y)*(-g_x+g_y) )/12.0f;
	fGuo[12] = (-g_x-g_y - uDg + 3.0f*(-u_x-u_y)*(-g_x-g_y) )/12.0f; // could simplify further
	fGuo[13] = (-g_x+g_z - uDg + 3.0f*(-u_x+u_z)*(-g_x+g_z) )/12.0f;
	fGuo[14] = (-g_x-g_z - uDg + 3.0f*(-u_x-u_z)*(-g_x-g_z) )/12.0f;

	fGuo[15] = ( g_y+g_z - uDg + 3.0f*( u_y+u_z)*( g_y+g_z) )/12.0f;
	fGuo[16] = ( g_y-g_z - uDg + 3.0f*( u_y-u_z)*( g_y-g_z) )/12.0f;
	fGuo[17] = (-g_y+g_z - uDg + 3.0f*(-u_y+u_z)*(-g_y+g_z) )/12.0f;
	fGuo[18] = (-g_y-g_z - uDg + 3.0f*(-u_y-u_z)*(-g_y-g_z) )/12.0f;

}


#ifdef CASSON
float compute_tau(float srtII, __global float* nonNewtonianParams)
{
	float sigma_y = nonNewtonianParams[0];
	float eta_inf = nonNewtonianParams[1];
	float m_c = 1E6;
	
	//printf("sigma_y = %f\n", sigma_y);
	//printf("eta_inf = %f\n", eta_inf);
	
	float a_c = (sqrt(eta_inf) + (1-exp(-sqrt(m_c*srtII)))*sqrt(sigma_y/srtII));
	float tau = 3.0f*a_c*a_c + 0.5f;
	
	//float nu = (sqrt(sigma_y/srtII) + sqrt(eta_inf))*(sqrt(sigma_y/srtII) + sqrt(eta_inf));
	//float tau = 3.0f*nu + 0.5f;

	if (tau < MIN_TAU) {
		tau = MIN_TAU;
		printf("Warning: tau <= %f\n", tau);
	}
	//tau = tau > 100.0 ? 100.0 : tau;
	//printf("Casson tau = %f\n", tau);
	
	return tau;
}

#elif POWER LAW
float compute_tau(float srtII, __global float* nonNewtonianParams)
{	
	float k = 0.001;
	//float n = 0.5;
	
	float nu = k/sqrt(srtII);
	float tau = 3.0f*nu + 0.5f;
	
	//tau = tau > 100.0 ? 100.0 : tau;
	if (tau < MIN_TAU) {
		tau = MIN_TAU;
		printf("Warning: tau <= %f\n", tau);
	}
	//printf("Power law tau = %f\n", tau);
	
	return tau;
}

#else
float compute_tau(float srtII, __global float* nonNewtonianParams)
{	
	return 1.0;
}
#endif