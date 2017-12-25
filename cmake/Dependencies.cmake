# These lists are later turned into target properties on main caffe library target
set(Caffe_LINKER_LIBS "")
set(Caffe_INCLUDE_DIRS "")
set(Caffe_DEFINITIONS "")
set(Caffe_COMPILE_OPTIONS "")

# ---[ Boost
if(WIN32)
  SET(BOOST_ROOT C:/local/boost_1_65_1)
  #SET(Boost_DEBUG ON)
  SET(Boost_COMPILER "-vc140")
  LINK_DIRECTORIES(C:/local/boost_1_65_1/lib64-msvc-14.0)
  SET(BOOST_LIBRARYDIR C:/local/boost_1_65_1/lib64-msvc-14.0)
  add_definitions(-DBOOST_THREAD_BUILD_DLL)
endif()
find_package(Boost REQUIRED COMPONENTS thread)
list(APPEND Caffe_INCLUDE_DIRS PRIVATE ${Boost_INCLUDE_DIRS})
list(APPEND Caffe_LINKER_LIBS PRIVATE ${Boost_LIBRARIES})

# ---[ Threads
find_package(Threads REQUIRED)
list(APPEND Caffe_LINKER_LIBS PRIVATE ${CMAKE_THREAD_LIBS_INIT})

# ---[ OpenMP
if(USE_OPENMP)
  # Ideally, this should be provided by the BLAS library IMPORTED target. However,
  # nobody does this, so we need to link to OpenMP explicitly and have the maintainer
  # to flick the switch manually as needed.
  #
  # Moreover, OpenMP package does not provide an IMPORTED target as well, and the
  # suggested way of linking to OpenMP is to append to CMAKE_{C,CXX}_FLAGS.
  # However, this naïve method will force any user of Caffe to add the same kludge
  # into their buildsystem again, so we put these options into per-target PUBLIC
  # compile options and link flags, so that they will be exported properly.
  find_package(OpenMP REQUIRED)
  list(APPEND Caffe_LINKER_LIBS PRIVATE ${OpenMP_CXX_FLAGS})
  list(APPEND Caffe_COMPILE_OPTIONS PRIVATE ${OpenMP_CXX_FLAGS})
endif()

# ---[ Google-glog
if (WIN32)
  if("${CMAKE_GENERATOR}" MATCHES "(Win64|IA64)")
    set(GLOG_INCLUDE_DIRS "C:/Program Files/glog/include")
    set(GLOG_LIBRARIES "C:/Program Files/glog/lib/glog.lib")
  else()
    set(GLOG_INCLUDE_DIRS "C:/Program Files (x86)/glog/include")
    set(GLOG_LIBRARIES "C:/Program Files (x86)/glog/lib/glog.lib")
 endif()
else ()
  include("cmake/External/glog.cmake")
endif()
list(APPEND Caffe_INCLUDE_DIRS PUBLIC ${GLOG_INCLUDE_DIRS})
list(APPEND Caffe_LINKER_LIBS PUBLIC ${GLOG_LIBRARIES})

# ---[ Google-gflags
if (WIN32)
  if("${CMAKE_GENERATOR}" MATCHES "(Win64|IA64)")
    set(GFLAGS_INCLUDE_DIRS "C:/Program Files/gflags/include")
    set(GFLAGS_LIBRARIES "C:/Program Files/gflags/lib/gflags_static.lib")
  else()
    set(GFLAGS_INCLUDE_DIRS "C:/Program Files (x86)/gflags/include")
    set(GFLAGS_LIBRARIES "C:/Program Files (x86)/gflags/lib/gflags.lib")
  endif()
else ()
  include("cmake/External/gflags.cmake")
endif()
list(APPEND Caffe_INCLUDE_DIRS PUBLIC ${GFLAGS_INCLUDE_DIRS})
list(APPEND Caffe_LINKER_LIBS PUBLIC ${GFLAGS_LIBRARIES})

# ---[ Google-protobuf
include(cmake/ProtoBuf.cmake)


# ---[ CUDA
include(cmake/Cuda.cmake)
if(NOT HAVE_CUDA)
  if(CPU_ONLY)
    message(STATUS "-- CUDA is disabled. Building without it...")
  else()
    message(WARNING "-- CUDA is not detected by cmake. Building without it...")
  endif()

  list(APPEND Caffe_DEFINITIONS PUBLIC -DCPU_ONLY)
else()
  find_package(DeepirAllocator REQUIRED)
  get_target_property(DeepirAllocator_INCLUDE_DIRS DeepirAllocator INTERFACE_INCLUDE_DIRECTORIES)
  list(APPEND Caffe_INCLUDE_DIRS PRIVATE ${DeepirAllocator_INCLUDE_DIRS})
  list(APPEND Caffe_LINKER_LIBS PRIVATE DeepirAllocator)
endif()

# ---[ OpenCV
if(USE_OPENCV)
  find_package(OpenCV QUIET COMPONENTS core highgui imgproc imgcodecs)
  if(NOT OpenCV_FOUND) # if not OpenCV 3.x, then imgcodecs are not found
    find_package(OpenCV REQUIRED COMPONENTS core highgui imgproc)
  endif()
  list(APPEND Caffe_INCLUDE_DIRS PUBLIC ${OpenCV_INCLUDE_DIRS})
  list(APPEND Caffe_LINKER_LIBS PUBLIC ${OpenCV_LIBS})
  message(STATUS "OpenCV found (${OpenCV_CONFIG_PATH})")
  list(APPEND Caffe_DEFINITIONS PUBLIC -DUSE_OPENCV)
endif()

# ---[ BLAS
if(NOT APPLE)
  set(BLAS "Atlas" CACHE STRING "Selected BLAS library")
  set_property(CACHE BLAS PROPERTY STRINGS "Atlas;Open;MKL")

  if(BLAS STREQUAL "Atlas" OR BLAS STREQUAL "atlas")
    find_package(Atlas REQUIRED)
    list(APPEND Caffe_INCLUDE_DIRS PUBLIC ${Atlas_INCLUDE_DIR})
    list(APPEND Caffe_LINKER_LIBS PUBLIC ${Atlas_LIBRARIES})
  elseif(BLAS STREQUAL "Open" OR BLAS STREQUAL "open")
    find_package(OpenBLAS REQUIRED)
    list(APPEND Caffe_INCLUDE_DIRS PUBLIC ${OpenBLAS_INCLUDE_DIR})
    list(APPEND Caffe_LINKER_LIBS PUBLIC ${OpenBLAS_LIB})
    if (NOT WIN32)
      list(APPEND Caffe_LINKER_LIBS PUBLIC pthread)
    endif()
  elseif(BLAS STREQUAL "MKL" OR BLAS STREQUAL "mkl")
    find_package(MKL REQUIRED)
    list(APPEND Caffe_INCLUDE_DIRS PUBLIC ${MKL_INCLUDE_DIR})
    list(APPEND Caffe_LINKER_LIBS PUBLIC ${MKL_LIBRARIES})
    list(APPEND Caffe_DEFINITIONS PUBLIC -DUSE_MKL)
  endif()
elseif(APPLE)
  find_package(vecLib REQUIRED)
  list(APPEND Caffe_INCLUDE_DIRS PUBLIC ${vecLib_INCLUDE_DIR})
  list(APPEND Caffe_LINKER_LIBS PUBLIC ${vecLib_LINKER_LIBS})

  if(VECLIB_FOUND)
    if(NOT vecLib_INCLUDE_DIR MATCHES "^/System/Library/Frameworks/vecLib.framework.*")
      list(APPEND Caffe_DEFINITIONS PUBLIC -DUSE_ACCELERATE)
    endif()
  endif()
endif()
