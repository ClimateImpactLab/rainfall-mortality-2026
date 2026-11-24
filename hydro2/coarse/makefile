SYS = Linux

UNAME := $(shell uname)

ifeq ($(UNAME), Darwin)
	OSARGS = -DSKIP_GETLINE
else
	OSARGS = 
endif

CC = mpic++
DEBUG = -g
OWD = ~/flooding/openworld
ODM = ~/flooding/opendims
CFLAGS = -std=c++11 -Wall -c $(DEBUG) -I $(OWD) -I $(ODM) -O3 -I $CONDA_PREFIX/include -std=c++17
LFLAGS = -Wall $(DEBUG) -O3 -L. -L$CONDA_PREFIX/lib -ltiff -lnetcdf -lnetcdf-cxx4

OBJS_MAIN = ../hydronet/HydroNet.o $(OWD)/datastr/GeographicMap.o $(OWD)/memory/Transients.o $(ODM)/dims/Dims.o $(ODM)/dims/Dimensions.o $(ODM)/dims/Dimensionless.o $(ODM)/measure/Units.o $(ODM)/measure/Inds.o $(ODM)/dims/GlobalDimensions.o $(OWD)/utils/Timer.o

all: main.o $(OBJS_MAIN) $(OWD)/datastr/Matrix.h $(OWD)/datastr/GeographicMap.h $(OWD)/datastr/PartialConfidenceTemporalGeographicMap.h
	$(CC) main.o $(OBJS_MAIN) -o main $(LFLAGS)

testtiff: testtiff.o
	$(CC) testtiff.o -o testtiff $(LFLAGS)

#Inference rule - states a general rule for compiling .o files
%.o : %.cpp
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	\rm $(OBJS_MAIN)
	\rm *.o main
