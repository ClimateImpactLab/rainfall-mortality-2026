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
#include <datastr/NetCDFGeographicMap.h>
#include <datastr/ConstantGeographicMap.h>
#include <datastr/DelayedTemporalGeographicMap.h>
#include <datastr/DelayedPartialConfidenceTemporalGeographicMap.h>
#include <datastr/TimeSeries.h>
#include <datastr/DividedRange.h>
#include <datastr/FileFormats.h>
#include <metrics/OLS.h>
#include <measure/Inds.h>
#include <memory/SerializationTools.h>
#include "../hydronet/HydroNet.h"
#include "../hydronet/HydroRun.h"
#include "../hydronet/ConstantForcing.h"
#include "../hydronet/NetCDFForcing.h"
#include "../hydronet/TemperatureForcing.h"
#include "../hydronet/NetCDFOutput.h"

bool regenerate = false;

using namespace openworld;

std::vector<std::string> parseCsvLine(const std::string& line) {
    std::vector<std::string> fields;
    std::string field;
    bool quoted = false;

    for (size_t i = 0; i < line.size(); ++i) {
        char c = line[i];

        if (c == '"') {
            // RFC-style escaped quote: ""
            if (quoted && i + 1 < line.size() && line[i + 1] == '"') {
                field += '"';
                ++i;
            } else {
                quoted = !quoted;
            }
        } else if (c == ',' && !quoted) {
            fields.push_back(field);
            field.clear();
        } else {
            field += c;
        }
    }

    if (quoted)
        throw std::runtime_error("Unclosed quote in CSV row.");

    fields.push_back(field);
    return fields;
}

std::vector<HydroOutputNode*> loadKnownOutputNodes(string filepath) {
    std::ifstream file(filepath);
    if (!file)
      throw std::runtime_error("Could not open: " + filepath);
    
    std::string line;
    // Read the very first line for headers
    if (!std::getline(file, line))
      throw runtime_error("Error: File is empty");

    int latIdx = -1, lonIdx = -1;

    // Identify column indexes for 'lat' and 'lon'
    auto headers = parseCsvLine(line);
    for (int i = 0; i < static_cast<int>(headers.size()); ++i) {
      std::string& header = headers[i];
      header.erase(std::remove_if(header.begin(), header.end(),
				  [](unsigned char c) { return std::isspace(c); }),
		   header.end());

      if (header == "lat") latIdx = i;
      if (header == "lon") lonIdx = i;
    }

    // Validate that both columns exist
    if (latIdx == -1 || lonIdx == -1)
      throw runtime_error("Error: Could not find 'lat' or 'lon' columns in header.");

    std::vector<HydroOutputNode*> nodes;

    // Read the remaining data lines
    while (std::getline(file, line)) {
	auto fields = parseCsvLine(line);
	
	if (latIdx < static_cast<int>(fields.size()) &&
	    lonIdx < static_cast<int>(fields.size())) {
	  nodes.push_back(new HydroOutputNode(std::stod(fields[latIdx]),
					      std::stod(fields[lonIdx])));
	}
    }

    file.close();

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
    TIFF* tiff = TIFFOpen("composite.tif", "r");
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
    DividedRange latitudes = DividedRange::withEnds(lat_min, lat_max, .1, Inds::lat);
    DividedRange longitudes = DividedRange(lon_min, lon_max, .1, Inds::lon);

    GeographicMap<double>* mask_lsm = NetCDFGeographicMap::loadNetCDF("era5_lsm.nc", "lsm", true);
    GeographicMap<bool>& mask_fine = *mask_lsm >= 0.5;
    
    GeographicMap<float>& slope = *MatrixGeographicMap<float>::loadTIFF(DividedRange(lat_min, lat_max, -dlat, Inds::lat),
									DividedRange(lon_min, lon_max, dlon, Inds::lon),
									"compositeslp.tif");
    slope /= 1e5; // don't produce transient!
    GeographicMap<double>* slope_fine = new GeographicMap<double>(slope);

    DInfinityMap* direction_fine = new DInfinityMap(*MatrixGeographicMap<float>::loadTIFF(DividedRange(lat_min, lat_max, -dlat, Inds::lat),
											  DividedRange(lon_min, lon_max, dlon, Inds::lon),
											  "compositeang.tif"));
    HydroNet net(*mask_lsm);

    // Construct bounding box to process: as many ERA5 cells as we can get without going to the edge.
    double proc_lon_min = max(lon_min + 0.1, lon_min + 0.1 / 2);
    double proc_lon_max = min(lon_max - 0.1, lon_max - 0.1 / 2);
    double proc_lat_max = min(lat_max - 0.1, lat_max - 0.1 / 2);
    double proc_lat_min = max(lat_min + 0.1, lat_min + 0.1 / 2);
    cout << proc_lon_min << " : " << proc_lon_max << ", " << proc_lat_min << " : " << proc_lat_max << endl;
    
    std::vector<HydroOutputNode*> outputNodes = loadKnownOutputNodes("../streamflows/grdd-meta.csv");

    if (regenerate) {
      net.generate(*direction_fine, mask_fine, *slope_fine, 10000.0, outputNodes);

      std::ofstream binaryFile("network.dat", std::ios::binary);
      PointerTracker tracker;
      net.streamInsert(binaryFile, tracker);
      binaryFile.close();
    } else {
      PointerReference reference;
      std::ifstream binaryFile("network.dat", std::ios::binary);
      DebugIStream debugIn(binaryFile);
      try {
	net.streamExtract(debugIn, reference);
	binaryFile.close();
      } catch (const std::exception& e) {
	cerr << "Caught an exception: " << e.what() << endl;
	cout << "Last tokens:" << endl << debugIn.getLastTokens() << endl;
	exit(-1);
      }

      // ConstantForcing forcing;
      
      // NetCDFHydroForcing forcing("global_monthly_flow_1950.nc4",
      // 				 "rainfall_flow", "tempmelt_flow", net);

      MonthlyTemperatureHydroForcing forcing("/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/tp_total",
					     "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/tmin",
					     "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/tmax",
					     "era5land_global_tp_total",
					     "era5land_global_tmin",
					     "era5land_global_tmax",
					     "tp_total",
					     "tmin",
					     "tmax",
					     1950, 1,
					     2025, 12,
					     net);

      HydroRunner runner(net, forcing, forcing.days(), 24);
      HydroRunResult result = runner.run();

      // writeRiverRunoffNetCDF(1, "era5_lsm.nc", "lsm",
      // 			     "river_flow.nc4",
      // 			     result);

      writeRiverRunoffNetCDF("global_monthly_flow_1950.nc4",
			     "rainfall_flow",
			     "river_flow.nc4",
			     result);

    }

    delete mask_lsm;
    
  } MPI_Finalize();
}
