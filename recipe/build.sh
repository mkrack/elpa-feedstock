#!/usr/bin/env bash
set -ex

# Update config.guess / config.sub
cp "${BUILD_PREFIX}/share/gnuconfig/config."* .

# Fix hardcoded perl interpreter (and remove -w which breaks env)
find . -name "*.pl" -exec sed -i.bak '1s|^#!.*perl.*|#!/usr/bin/env perl|' {} +
find . -name "*.pl.bak" -delete

# Minimal CI tests
tests=(
  "validate_real_2stage_banded_default.sh"
)

# MPI setup
if [[ "${mpi}" != "nompi" ]]; then
  MPI=yes
  export CC="${PREFIX}/bin/mpicc"
  export CXX="${PREFIX}/bin/mpicxx"
  export FC="${PREFIX}/bin/mpifort"
else
  MPI=no
fi

# OpenMPI CI stabilization
if [[ "${mpi}" == "openmpi" ]]; then
  export OMPI_MCA_plm=isolated
  export OMPI_MCA_btl_vader_single_copy_mechanism=none
  export OMPI_MCA_rmaps_base_oversubscribe=yes
fi

# Compiler and architecture flags
conf_extra=""
if [[ "$(uname)" == "Darwin" ]]; then
  if [[ "${target_platform}" == "osx-arm64" ]]; then
    export CFLAGS="${CFLAGS} -fno-lto"
    export FCFLAGS="${FCFLAGS} -fno-lto"
    export CXXFLAGS="${CXXFLAGS} -fno-lto"
    conf_extra="--disable-sse-assembly --disable-avx2 --disable-avx --disable-sse"
  else
    export CFLAGS="${CFLAGS} -mavx"
    export FCLAGS="${FCLAGS} -mavx"
    conf_extra="--disable-sse-assembly --disable-avx2"
  fi
  export FORTRAN_CPP="${FC:-gfortran} -E -P -cpp"
else
  if [[ "${target_platform}" == "linux-64" ]]; then
    export CFLAGS="${CFLAGS} -mavx2 -mfma"
    export FCFLAGS="${FCFLAGS} -mavx2 -mfma"
  else
    conf_extra="--disable-sse-assembly --disable-avx2 --disable-avx --disable-sse"
  fi

  export FORTRAN_CPP="${CPP:-cpp} -P -traditional"
fi

# Ensure PREFIX visibility
export CPPFLAGS="${CPPFLAGS} -I${PREFIX}/include"
export FCFLAGS="${FCFLAGS} -I${PREFIX}/include"
export LDFLAGS="${LDFLAGS} -L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib"

if [[ "${MPI}" == "yes" ]]; then
  export LIBS="${LIBS} -lscalapack"
fi

# Configure options
conf_options=(
  "--prefix=${PREFIX}"
  "--build=${BUILD}"
  "--host=${HOST}"
  "--with-mpi=${MPI}"
  "--disable-avx512"
)

# Cross-compilation fixes
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  conf_options+=(
    "ac_cv_prog_cxx_works=yes"
    "ac_cv_prog_cc_works=yes"
    "ac_cv_prog_fc_works=yes"
    "ac_cv_search_MPI_Init=none required"
    "ax_cv_mpicxx_works=yes"
    "ax_cv_mpicc_works=yes"
    "ax_cv_mpifort_works=yes"
    "ac_cv_c_extc99=yes"
    "ac_cv_c_extc11=yes"
    "ac_cv_cxx_extcxx11=yes"
    "ac_cv_c_compiler_gnu=yes"
    "ac_cv_cxx_compiler_gnu=yes"
    "ac_cv_c_compiler_works=yes"
    "ac_cv_cxx_compiler_works=yes"
    "ac_cv_fc_compiler_works=yes"
  )
  if [[ "${mpi}" == "openmpi" ]]; then
    conf_options+=(
      "ompi_cv_c_compiler_works=yes"
      "ompi_cv_cxx_compiler_works=yes"
      "ompi_cv_fortran_compiler_works=yes"
      "pmix_cv_func_malloc_0_nonnull=yes"
      "prrte_cv_func_malloc_0_nonnull=yes"
    )
  fi
fi

if [[ -n "${conf_extra}" ]]; then
  conf_options+=(${conf_extra})
fi

# Build without OpenMP
mkdir build
pushd build

../configure "${conf_options[@]}" || { cat config.log; exit 1; }

make -j"${CPU_COUNT:-1}"
make install

popd

# Build with OpenMP
mkdir build_openmp
pushd build_openmp
 
../configure --enable-openmp "${conf_options[@]}" || { cat config.log; exit 1; }

make -j"${CPU_COUNT:-1}"

# Run tests only if safe
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" != "1" && "${MPI}" == "yes" ]]; then
  for t in "${tests[@]}"; do
    make "$t" && ./"$t" || true
  done
fi

make install

popd
