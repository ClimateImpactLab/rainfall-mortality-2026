SYS = Linux

UNAME := $(shell uname)

ifeq ($(UNAME), Darwin)
	OSARGS = -DSKIP_GETLINE
else
	OSARGS = 
endif

CC = mpic++
DEBUG = -g
OWD = ~/projects/openworld
ODM = ~/projects/opendims
CFLAGS = -std=c++11 -Wall -Wvla-cxx-extension -c $(DEBUG) -I $(OWD) -I $(ODM) -O3 -I/opt/homebrew/include #-I $(OWD)/ext/gzstream $(OSARGS)
LFLAGS = -Wall $(DEBUG) -O3 -L. -L/opt/homebrew/lib -ltiff -lnetcdf -lnetcdf-cxx4 #-L $(OWD)/ext/gzstream -lgzstream -lz

OBJS_MAIN = ../hydronet/HydroNet.o $(OWD)/datastr/GeographicMap.o $(OWD)/memory/Transients.o $(ODM)/dims/Dims.o $(ODM)/dims/Dimensions.o $(ODM)/dims/Dimensionless.o $(ODM)/measure/Units.o $(ODM)/measure/Inds.o $(ODM)/dims/GlobalDimensions.o $(OWD)/utils/Timer.o #$(OWD)/ext/gzstream/gzstream.o $(OWD)/geotiff/tiffIO.o $(OWD)/geotiff/commonLib.o 

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
