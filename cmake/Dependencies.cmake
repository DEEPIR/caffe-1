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
  if(NOT CPU_ONLY)
    find_package(DeepirAllocator REQUIRED)
    get_target_property(DeepirAllocator_INCLUDE_DIRS DeepirAllocator INTERFACE_INCLUDE_DIRECTORIES)
    list(APPEND Caffe_INCLUDE_DIRS PRIVATE ${DeepirAllocator_INCLUDE_DIRS})
    list(APPEND Caffe_LINKER_LIBS PRIVATE DeepirAllocator)
  endif()
endif()

# ---[ OpenCV
if(USE_OPENCV)
  find_package(OpenCV QUIET COMPONENTS core imgproc imgcodecs)
  if(NOT OpenCV_FOUND) # if not OpenCV 3.x, then imgcodecs are not found
    find_package(OpenCV REQUIRED COMPONENTS core imgproc)
  endif()
  list(APPEND Caffe_INCLUDE_DIRS PUBLIC ${OpenCV_INCLUDE_DIRS})
  list(APPEND Caffe_LINKER_LIBS PUBLIC ${OpenCV_LIBS})
  message(STATUS "OpenCV found (${OpenCV_CONFIG_PATH})")
  list(APPEND Caffe_DEFINITIONS PUBLIC -DUSE_OPENCV)
endif()

# ---[ BLAS
find_package(OpenBLAS REQUIRED)
list(APPEND Caffe_INCLUDE_DIRS PUBLIC ${OpenBLAS_INCLUDE_DIR})
list(APPEND Caffe_LINKER_LIBS PUBLIC ${OpenBLAS_LIB})
if (NOT WIN32)
  list(APPEND Caffe_LINKER_LIBS PUBLIC pthread)
endif()

# ---[ Python
if(BUILD_python)
  if(NOT "${python_version}" VERSION_LESS "3.0.0")
    # use python3
    find_package(PythonInterp 3.0)
    find_package(PythonLibs 3.0)
    find_package(NumPy 1.7.1)
    # Find the matching boost python implementation
    set(version ${PYTHONLIBS_VERSION_STRING})

    STRING( REGEX REPLACE "[^0-9]" "" boost_py_version ${version} )
    find_package(Boost COMPONENTS "python-py${boost_py_version}")
    set(Boost_PYTHON_FOUND ${Boost_PYTHON-PY${boost_py_version}_FOUND})

    while(NOT "${version}" STREQUAL "" AND NOT Boost_PYTHON_FOUND)
      STRING( REGEX REPLACE "([0-9.]+).[0-9]+" "\\1" version ${version} )

      STRING( REGEX REPLACE "[^0-9]" "" boost_py_version ${version} )
      find_package(Boost COMPONENTS "python-py${boost_py_version}")
      set(Boost_PYTHON_FOUND ${Boost_PYTHON-PY${boost_py_version}_FOUND})

      STRING( REGEX MATCHALL "([0-9.]+).[0-9]+" has_more_version ${version} )
      if("${has_more_version}" STREQUAL "")
        break()
      endif()
    endwhile()
    if(NOT Boost_PYTHON_FOUND)
      find_package(Boost COMPONENTS python)
    endif()
  else()
    # disable Python 3 search
    find_package(PythonInterp 2.7)
    find_package(PythonLibs 2.7)
    find_package(NumPy 1.7.1)
    find_package(Boost COMPONENTS python)
  endif()
  if(PYTHONLIBS_FOUND AND NUMPY_FOUND AND Boost_PYTHON_FOUND)
    set(HAVE_PYTHON TRUE)
    if(BUILD_python_layer)
      list(APPEND Caffe_DEFINITIONS PUBLIC -DWITH_PYTHON_LAYER)
      list(APPEND Caffe_INCLUDE_DIRS PRIVATE ${PYTHON_INCLUDE_DIRS} ${NUMPY_INCLUDE_DIR} PUBLIC ${Boost_INCLUDE_DIRS})
      list(APPEND Caffe_LINKER_LIBS PRIVATE ${PYTHON_LIBRARIES} PUBLIC ${Boost_LIBRARIES})
    endif()
  endif()
endif()
