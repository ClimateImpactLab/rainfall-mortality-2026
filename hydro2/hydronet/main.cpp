#define USE_DUMMY
#define COMPARE_SNOW

#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <stdio.h>
#include <mpi.h>
#include <tiffio.h>
#include <geotiffio.h>
#include <xtiffio.h>
#include <datastr/GeographicMap.h>
#include <datastr/ConstantGeographicMap.h>
#include <datastr/DelayedTemporalGeographicMap.h>
#include <datastr/DelayedPartialConfidenceTemporalGeographicMap.h>
#include <datastr/TimeSeries.h>
#include <datastr/DividedRange.h>
#include <datastr/FileFormats.h>
#include <metrics/OLS.h>
#include <measure/Inds.h>
#include <memory/SerializationTools.h>
#include "HydroNet.h"

using namespace openworld;

std::vector<HydroOutputNode*> loadKnownOutputNodes(string filepath) {
    std::ifstream file(filepath);

    std::string line;
    // Read the very first line for headers
    if (!std::getline(file, line))
      throw runtime_error("Error: File is empty");

    std::stringstream ss(line);
    std::string header;
    int latIdx = -1, lonIdx = -1;
    int currentIdx = 0;

    // Identify column indexes for 'lat' and 'lon'
    while (std::getline(ss, header, ',')) {
        // Strip potential whitespace or carriage returns from header
        header.erase(std::remove_if(header.begin(), header.end(), ::isspace), header.end());
        
        if (header == "lat") latIdx = currentIdx;
        if (header == "lon") lonIdx = currentIdx;
        currentIdx++;
    }

    // Validate that both columns exist
    if (latIdx == -1 || lonIdx == -1)
      throw runtime_error("Error: Could not find 'lat' or 'lon' columns in header.");

    std::vector<HydroOutputNode*> nodes;

    // Read the remaining data lines
    while (std::getline(file, line)) {
        std::stringstream lineStream(line);
        std::string value;
        int fieldIdx = 0;
        
        double latVal = 0.0;
        double lonVal = 0.0;
        bool foundLat = false;
        bool foundLon = false;

        while (std::getline(lineStream, value, ',')) {
            if (fieldIdx == latIdx) {
                latVal = std::stod(value); // Convert string to double
                foundLat = true;
            }
            if (fieldIdx == lonIdx) {
                lonVal = std::stod(value); // Convert string to double
                foundLon = true;
            }
            fieldIdx++;
        }

        // Only save if both fields were successfully extracted from the row
        if (foundLat && foundLon)
	  nodes.push_back(new HydroOutputNode(latVal, lonVal));
    }

    file.close();

    return nodes;
}

std::vector<HydroOutputNode*> constructEdgeNodes(double proc_lat_min, double proc_lat_max,
						 double proc_lon_min, double proc_lon_max,
						 double dlat, double dlon) {
  DividedRange across = DividedRange::withEnds(proc_lon_min, proc_lon_max, dlon, Inds::lon);
  DividedRange updown = DividedRange::withEnds(proc_lat_min, proc_lat_max, dlat, Inds::lat);

  std::vector<HydroOutputNode*> nodes;
  // top edge
  for (int ii = 0; ii < across.count(); ii++)
    nodes.push_back(new HydroOutputNode(proc_lat_max, across.getCellCenter(ii).getValue()));
  // right edge
  for (int ii = 0; ii < updown.count(); ii++)
    nodes.push_back(new HydroOutputNode(updown.getCellCenter(ii).getValue(), proc_lon_max));
  // bottom edge
  for (int ii = 0; ii < across.count(); ii++)
    nodes.push_back(new HydroOutputNode(proc_lat_min, across.getCellCenter(ii).getValue()));
  // right edge
  for (int ii = 0; ii < updown.count(); ii++)
    nodes.push_back(new HydroOutputNode(updown.getCellCenter(ii).getValue(), proc_lon_min));

  return nodes;
}

// Helper: loadGeoTransform reads pixel-to-world transform
bool loadGeoTransform(TIFF* tiff, double gt[6]) {
    // gt convention (GDAL-style):
    // gt[0] = top-left x
    // gt[1] = w-e pixel resolution
    // gt[2] = row rotation (typically 0)
    // gt[3] = top-left y
    // gt[4] = column rotation (typically 0)
    // gt[5] = n-s pixel resolution (typically negative)

    double *tiePoints = nullptr;
    double *pixelScale = nullptr;
    int countTiePoints = 0, countPixelScale = 0;

    if (TIFFGetField(tiff, TIFFTAG_GEOTIEPOINTS, &countTiePoints, &tiePoints) &&
        TIFFGetField(tiff, TIFFTAG_GEOPIXELSCALE, &countPixelScale, &pixelScale) &&
        countTiePoints >= 6 && countPixelScale >= 2) {

        // Assume first tie point is upper-left corner or some reference point
        double i = tiePoints[0];
        double j = tiePoints[1];
        double x = tiePoints[3];
        double y = tiePoints[4];

        double scaleX = pixelScale[0];
        double scaleY = pixelScale[1];

        // Simple north-up assumption: no rotation
        gt[1] = scaleX;
        gt[2] = 0.0;
        gt[4] = 0.0;
        gt[5] = -fabs(scaleY); // y decreases as row increases

        // Compute top-left corner georeferenced coords (for (0,0)):
        // x_geo = x + (0 - i)*scaleX
        // y_geo = y + (0 - j)*scaleY
        gt[0] = x - i * scaleX;
        gt[3] = y - j * scaleY;

        return true;
    }

    return false;
}

int main(int argc, const char* argv[])
{
  MPI_Init(NULL,NULL); {
    TIFF* tiff = TIFFOpen("../composite.tif", "r");
    if (!tiff) return 1;

    double gt[6];
    if (!loadGeoTransform(tiff, gt)) {
        std::cerr << "No usable geotransform in GeoTIFF" << std::endl;
        TIFFClose(tiff);
        return -1;
    }

    uint32_t width, height;
    TIFFGetField(tiff, TIFFTAG_IMAGEWIDTH, &width);
    TIFFGetField(tiff, TIFFTAG_IMAGELENGTH, &height);

    auto geo_x = [&](int col, int row) {
        return gt[0] + col * gt[1] + row * gt[2];
    };
    auto geo_y = [&](int col, int row) {
        return gt[3] + col * gt[4] + row * gt[5];
    };

    double x0 = geo_x(0, 0);
    double y0 = geo_y(0, 0);
    double x1 = geo_x(width, 0);
    double y1 = geo_y(0, height);

    double lon_min = std::min(x0, x1);
    double lon_max = std::max(x0, x1);
    double lat_max = std::max(y0, y1);
    double lat_min = std::min(y0, y1);

    double dlon = gt[1];
    double dlat = gt[5]; // usually negative if origin is top-left

    cout << lon_min << " : " << dlon << " : " << lon_max << ", " << lat_min << " : " << dlat << " : " << lat_max << endl;

    // What is the range that fully includes the fine resolution?
    DividedRange latitudes = DividedRange::withEnds(floor(lat_min / .25) * .25, ceil(lat_max / .25) * .25, .25, Inds::lat);
    DividedRange longitudes = DividedRange::withEnds(floor(lon_min / .25) * .25, ceil(lon_max / .25) * .25, .25, Inds::lon);

    MatrixGeographicMap<double>* mask_coarse = new MatrixGeographicMap<double>(latitudes, longitudes);
    mask_coarse->loadConstantInto(1.0);
    cout << mask_coarse->getLatitudes().count() << ", " << mask_coarse->getLongitudes().count() << endl;
    MatrixGeographicMap<bool>* mask_fine = new MatrixGeographicMap<bool>(DividedRange::withEnds(lat_min, lat_max, -dlat, Inds::lat),
									 DividedRange::withEnds(lon_min, lon_max, dlon, Inds::lon));
    mask_fine->loadConstantInto(true);

    GeographicMap<float>& slope = *MatrixGeographicMap<float>::loadTIFF(DividedRange::withEnds(lat_min, lat_max, -dlat, Inds::lat),
									DividedRange::withEnds(lon_min, lon_max, dlon, Inds::lon),
									"../compositeslp.tif");
    slope /= 1e5; // don't produce transient!

    GeographicMap<double>* slope_fine = new GeographicMap<double>(slope);

    DInfinityMap* direction_fine = new DInfinityMap(*MatrixGeographicMap<float>::loadTIFF(DividedRange::withEnds(lat_min, lat_max, -dlat, Inds::lat),
											  DividedRange::withEnds(lon_min, lon_max, dlon, Inds::lon),
											  "../compositeang.tif"));
    HydroNet* net = new HydroNet(*mask_coarse);

    // Construct bounding box to process: as many ERA5 cells as we can get without going to the edge.
    double proc_lon_min = max(lon_min + 0.1, lon_min + 0.25 / 2);
    double proc_lon_max = min(lon_max - 0.1, lon_max - 0.25 / 2);
    double proc_lat_max = min(lat_max - 0.1, lat_max - 0.25 / 2);
    double proc_lat_min = max(lat_min + 0.1, lat_min + 0.25 / 2);
    cout << proc_lon_min << " : " << proc_lon_max << ", " << proc_lat_min << " : " << proc_lat_max << endl;
    
    std::vector<HydroOutputNode*> knownOutputNodes = loadKnownOutputNodes("../streamflows/grdd-meta.csv");
    std::vector<HydroOutputNode*> edgeOutputNodes = constructEdgeNodes(proc_lat_min, proc_lat_max, proc_lon_min, proc_lon_max,
								       -dlat, dlon);

    std::vector<HydroOutputNode*> outputNodes = knownOutputNodes;
    outputNodes.reserve(knownOutputNodes.size() + edgeOutputNodes.size()); 
    outputNodes.insert(outputNodes.end(), edgeOutputNodes.begin(), edgeOutputNodes.end()); 

    net->generateSurfaceNodeFiles(*direction_fine, *mask_fine, *slope_fine, 10000.0, outputNodes);

    // cout << "Loading elevation" << endl;
    // model->setElevation(MatrixGeographicMap<double>::loadDelimited(DividedRange::withEnds(lat_min, lat_max, -dlat, Inds::lat),
    // 								   DividedRange::withEnds(lon_min, lon_max, dlon, Inds::lon),
    // 								   "elevation.tsv", NULL, '\t'));

    // Only do processing within the 
    net->generateFromSurfaceNodeFiles(outputNodes);
    
    std::ofstream binaryFile("output.dat", std::ios::binary);
    PointerTracker tracker;
    net->streamInsert(binaryFile, tracker);
    binaryFile.close();
    
  } MPI_Finalize();
}



