#include <netcdf>
#include <vector>
#include <string>
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <memory>
#include <sstream>
#include <iomanip>

using namespace netCDF;

namespace openworld {

static int nearestGridIndex(const std::vector<double>& coords, double value) {
  if (coords.empty())
    return -1;

  bool ascending = coords.back() >= coords.front();

  auto compare = [ascending](double a, double b) {
    return ascending ? a < b : a > b;
  };

  std::vector<double>::const_iterator pos =
    std::lower_bound(coords.begin(), coords.end(), value, compare);

  size_t candidate = 0;

  if (pos == coords.begin()) {
    candidate = 0;
  } else if (pos == coords.end()) {
    candidate = coords.size() - 1;
  } else {
    size_t right = (size_t) std::distance(coords.begin(), pos);
    size_t left = right - 1;

    candidate =
      std::abs(coords[left] - value) <= std::abs(coords[right] - value)
      ? left : right;
  }

  // Require an effectively exact grid-coordinate match.  This catches
  // accidental use of incompatible grids rather than silently shifting data.
  double spacing = coords.size() > 1
    ? std::abs(coords[1] - coords[0])
    : 1.0;

  double tolerance = std::max(1e-8, spacing * 1e-6);

  if (std::abs(coords[candidate] - value) > tolerance)
    return -1;

  return (int) candidate;
}


void writeRiverRunoffNetCDF(const std::string& weatherPath,
                            const std::string& weatherVariableName,
                            const std::string& outputPath,
                            const HydroRunResult& result,
                            const std::string& outputVariableName =
                              "river_m3_day") {
  NcFile input(weatherPath, NcFile::read);

  NcVar weatherVar = input.getVar(weatherVariableName);
  if (weatherVar.isNull())
    throw std::runtime_error("Could not find weather variable: " +
                             weatherVariableName);

  std::vector<NcDim> dims = weatherVar.getDims();
  if (dims.size() != 3)
    throw std::runtime_error(
      "Weather variable must have dimensions day x lat x lon.");

  const size_t nday = dims[0].getSize();
  const size_t nlat = dims[1].getSize();
  const size_t nlon = dims[2].getSize();

  NcVar latVar = input.getVar("latitude");
  NcVar lonVar = input.getVar("longitude");

  if (latVar.isNull() || lonVar.isNull())
    throw std::runtime_error(
      "Weather file must contain latitude and longitude variables.");

  std::vector<double> lats(nlat);
  std::vector<double> lons(nlon);
  latVar.getVar(lats.data());
  lonVar.getVar(lons.data());

  // Flat NetCDF-order array: [day][lat][lon].
  std::vector<double> riverValues(nday * nlat * nlon, 0.0);
  std::vector<double> storageValues(nday * nlat * nlon, 0.0);

  size_t mappedRiverNodes = 0;

  for (std::map<HydroNode*, std::vector<double> >::const_iterator it =
         result.river_m3_day.begin();
       it != result.river_m3_day.end();
       ++it) {

    HydroNode* node = it->first;
    const std::vector<double>& dailyFlows = it->second;

    if (node == NULL)
      continue;

    if (dailyFlows.size() != nday) {
      cout << dailyFlows.size() << " vs. " << nday << endl;
      throw std::runtime_error(
        "HydroRunResult day count does not match weather NetCDF.");
    }

    int latIndex = nearestGridIndex(
      lats, node->getLatitude().getValue());
    int lonIndex = nearestGridIndex(
      lons, node->getLongitude().getValue());

    // The river node lies outside the forcing domain, or its coordinates
    // do not align with the forcing grid.
    if (latIndex < 0 || lonIndex < 0)
      continue;

    mappedRiverNodes++;
    
    for (size_t day = 0; day < nday; ++day) {
      double flow = dailyFlows[day];

      if (!std::isfinite(flow))
        continue;

      size_t index =
        day * nlat * nlon +
        (size_t) latIndex * nlon +
        (size_t) lonIndex;

      riverValues[index] += flow;
    }
  }

  if (mappedRiverNodes == 0)
    throw std::runtime_error("No river nodes mapped to output grid.");

  for (std::map<HydroNode*, std::vector<double> >::const_iterator it =
	 result.storage_m3_end_day.begin();
       it != result.storage_m3_end_day.end();
       ++it) {
    
    HydroNode* node = it->first;
    const std::vector<double>& dailyStorage = it->second;
    
    if (node == NULL)
      continue;

    if (dailyStorage.size() != nday)
      throw std::runtime_error("Storage record day count does not match weather NetCDF.");

    int latIndex = nearestGridIndex(lats, node->getLatitude().getValue());
    int lonIndex = nearestGridIndex(lons, node->getLongitude().getValue());

    // Node is outside the regional weather grid.
    if (latIndex < 0 || lonIndex < 0)
      continue;

    for (size_t day = 0; day < nday; ++day) {
      double storage_m3 = dailyStorage[day];
      
      if (!std::isfinite(storage_m3))
	continue;

      size_t index =
	day * nlat * nlon +
	(size_t) latIndex * nlon +
	(size_t) lonIndex;
      
      // Sum all HydroNet nodes that fall in this forcing-grid cell.
      storageValues[index] += static_cast<float>(storage_m3);
    }
  }

  NcFile output(outputPath, NcFile::replace);

  NcDim dayDim = output.addDim(dims[0].getName(), nday);
  NcDim latDim = output.addDim(dims[1].getName(), nlat);
  NcDim lonDim = output.addDim(dims[2].getName(), nlon);

  // Preserve latitude and longitude axes.
  NcVar outLat = output.addVar("latitude", ncDouble, latDim);
  NcVar outLon = output.addVar("longitude", ncDouble, lonDim);
  outLat.putVar(lats.data());
  outLon.putVar(lons.data());

  // Preserve/create the temporal coordinate if the input has one.
  std::vector<double> times(nday);
  NcVar inputTime = input.getVar(dims[0].getName());

  if (!inputTime.isNull()) {
    inputTime.getVar(times.data());
  } else {
    for (size_t day = 0; day < nday; ++day)
      times[day] = (double) day;
  }

  NcVar outTime = output.addVar(dims[0].getName(), ncDouble, dayDim);
  outTime.putVar(times.data());

  NcVar riverVar = output.addVar(
    outputVariableName,
    ncFloat,
    std::vector<NcDim>{dayDim, latDim, lonDim});

  riverVar.putAtt("long_name",
                  "daily routed river outflow from HydroNet nodes");
  riverVar.putAtt("units", "m3 day-1");
  riverVar.putVar(riverValues.data());

  NcVar outputVar = output.addVar("output_m3_day",
				  ncFloat,
				  std::vector<NcDim>{dayDim, latDim, lonDim});

  NcVar storageVar = output.addVar("stored_water_m3",
				   ncFloat,
				   std::vector<NcDim>{dayDim, latDim, lonDim});
  
  storageVar.putAtt("long_name",
		    "water stored in HydroNet nodes at end of day");

  storageVar.putAtt("units", "m3");

  storageVar.putAtt("comment",
		    "Sum of end-of-day storage across all surface, non-river, and river "
		    "HydroNet nodes mapped to each weather-grid cell.");

  storageVar.putVar(storageValues.data());
}

void writeRiverRunoffNetCDF(size_t nday, const std::string& gridPath,
                            const std::string& variableName,
                            const std::string& outputPath,
                            const HydroRunResult& result,
                            const std::string& outputVariableName =
                              "river_m3_day") {
  NcFile input(gridPath, NcFile::read);

  NcVar var = input.getVar(variableName);
  if (var.isNull())
    throw std::runtime_error("Could not find weather variable: " +
                             variableName);

  std::vector<NcDim> dims = var.getDims();
  if (dims.size() != 3)
    throw std::runtime_error(
      "Weather variable must have dimensions day x lat x lon.");

  //const size_t days = dims[0].getSize();
  const size_t nlat = dims[1].getSize();
  const size_t nlon = dims[2].getSize();

  NcVar latVar = input.getVar("latitude");
  NcVar lonVar = input.getVar("longitude");

  if (latVar.isNull() || lonVar.isNull())
    throw std::runtime_error(
      "Weather file must contain latitude and longitude variables.");

  std::vector<double> lats(nlat);
  std::vector<double> lons(nlon);
  latVar.getVar(lats.data());
  lonVar.getVar(lons.data());

  // Flat NetCDF-order array: [day][lat][lon].
  std::vector<double> riverValues(nday * nlat * nlon, 0.0);
  std::vector<double> storageValues(nday * nlat * nlon, 0.0);

  size_t mappedRiverNodes = 0;

  for (std::map<HydroNode*, std::vector<double> >::const_iterator it =
         result.river_m3_day.begin();
       it != result.river_m3_day.end();
       ++it) {

    HydroNode* node = it->first;
    const std::vector<double>& dailyFlows = it->second;

    if (node == NULL)
      continue;

    if (dailyFlows.size() != nday) {
      cout << dailyFlows.size() << " vs. " << nday << endl;
      throw std::runtime_error(
        "HydroRunResult day count does not match weather NetCDF.");
    }

    int latIndex = nearestGridIndex(
      lats, node->getLatitude().getValue());
    int lonIndex = nearestGridIndex(
      lons, node->getLongitude().getValue());

    // The river node lies outside the forcing domain, or its coordinates
    // do not align with the forcing grid.
    if (latIndex < 0 || lonIndex < 0)
      continue;

    mappedRiverNodes++;
    
    for (size_t day = 0; day < nday; ++day) {
      double flow = dailyFlows[day];

      if (!std::isfinite(flow))
        continue;

      size_t index =
        day * nlat * nlon +
        (size_t) latIndex * nlon +
        (size_t) lonIndex;

      riverValues[index] += flow;
    }
  }

  if (mappedRiverNodes == 0)
    throw std::runtime_error("No river nodes mapped to output grid.");

  for (std::map<HydroNode*, std::vector<double> >::const_iterator it =
	 result.storage_m3_end_day.begin();
       it != result.storage_m3_end_day.end();
       ++it) {
    
    HydroNode* node = it->first;
    const std::vector<double>& dailyStorage = it->second;
    
    if (node == NULL)
      continue;

    if (dailyStorage.size() != nday)
      throw std::runtime_error(
			       "Storage record day count does not match weather NetCDF.");

    int latIndex = nearestGridIndex(lats, node->getLatitude().getValue());
    int lonIndex = nearestGridIndex(lons, node->getLongitude().getValue());

    // Node is outside the regional weather grid.
    if (latIndex < 0 || lonIndex < 0)
      continue;

    for (size_t day = 0; day < nday; ++day) {
      double storage_m3 = dailyStorage[day];
      
      if (!std::isfinite(storage_m3))
	continue;

      size_t index =
	day * nlat * nlon +
	(size_t) latIndex * nlon +
	(size_t) lonIndex;
      
      // Sum all HydroNet nodes that fall in this forcing-grid cell.
      storageValues[index] += storage_m3;
    }
  }

  NcFile output(outputPath, NcFile::replace);

  NcDim dayDim = output.addDim(dims[0].getName(), nday);
  NcDim latDim = output.addDim(dims[1].getName(), nlat);
  NcDim lonDim = output.addDim(dims[2].getName(), nlon);

  // Preserve latitude and longitude axes.
  NcVar outLat = output.addVar("latitude", ncDouble, latDim);
  NcVar outLon = output.addVar("longitude", ncDouble, lonDim);
  outLat.putVar(lats.data());
  outLon.putVar(lons.data());

  // Preserve/create the temporal coordinate if the input has one.
  std::vector<double> times(nday);
  NcVar inputTime = input.getVar(dims[0].getName());

  if (!inputTime.isNull()) {
    inputTime.getVar(times.data());
  } else {
    for (size_t day = 0; day < nday; ++day)
      times[day] = (double) day;
  }

  NcVar outTime = output.addVar(dims[0].getName(), ncDouble, dayDim);
  outTime.putVar(times.data());

  NcVar riverVar = output.addVar(
    outputVariableName,
    ncDouble,
    std::vector<NcDim>{dayDim, latDim, lonDim});

  riverVar.putAtt("long_name",
                  "daily routed river outflow from HydroNet nodes");
  riverVar.putAtt("units", "m3 day-1");
  riverVar.putVar(riverValues.data());

  NcVar storageVar = output.addVar("stored_water_m3",
				   ncDouble,
				   std::vector<NcDim>{dayDim, latDim, lonDim});
  
  storageVar.putAtt("long_name",
		    "water stored in HydroNet nodes at end of day");

  storageVar.putAtt("units", "m3");

  storageVar.putAtt("comment",
		    "Sum of end-of-day storage across all surface, non-river, and river "
		    "HydroNet nodes mapped to each weather-grid cell.");

  storageVar.putVar(storageValues.data());
}

class MonthlyHydroNetCDFOutput : public HydroDailyOutput {
private:
  std::string gridPath;
  std::string outputDirectory;
  int firstYear, firstMonth;

  unsigned currentMonthFirstDay;
  unsigned currentMonthDays;
  int currentYear;
  int currentMonth

  // Current output month/file and its NetCDF variables.
  std::unique_ptr<NcFile> output;
  NcVar riverVar, outputVar, storageVar;
  size_t nlat, nlon;
  unsigned monthFirstDay;
  unsigned monthDays;

  std::vector<HydroOutputNode*> outputNodes;
  std::map<HydroOutputNode*, size_t> outputNodeIndex;

  NcVar outputFlowVar;
  std::vector<float> outputFlowValues;

  std::vector<float> riverValues;    // one day only
  std::vector<float> storageValues;  // one day only

  std::map<HydroNode*, size_t> riverGridIndex;
  std::map<HydroOutputNode*, size_t> outputGridIndex;
  std::map<HydroNode*, size_t> storageGridIndex;

  void openMonthForDay(unsigned absoluteDay);
  void closeMonth();

public:
  MonthlyHydroNetCDFOutput(HydroNet& net,
                           const std::string& gridPath,
                           const std::string& outputDirectory,
                           int firstYear, int firstMonth) {
    for (HydroNode* node : net.collectReachableNodes()) {
      int latIndex = nearestGridIndex(lats, node->getLatitude().getValue());
      int lonIndex = nearestGridIndex(lons, node->getLongitude().getValue());

      if (latIndex < 0 || lonIndex < 0)
	continue;

      size_t index =
	static_cast<size_t>(latIndex) * nlon +
	static_cast<size_t>(lonIndex);
      
      storageGridIndex[node] = index;
      
      if (node->isRiver())
	riverGridIndex[node] = index;
      
      if (node->isOutput())
	outputGridIndex[static_cast<HydroOutputNode*>(node)] = index;
    }

    for (std::set<HydroNode*>::const_iterator it = nodes.begin();
	 it != nodes.end(); ++it) {
      HydroNode* node = *it;
      
      if (node != NULL && node->isOutput()) {
	HydroOutputNode* outputNode =
	  static_cast<HydroOutputNode*>(node);
	
	outputNodeIndex[outputNode] = outputNodes.size();
	outputNodes.push_back(outputNode);
      }
    }

    outputFlowValues.assign(outputNodes.size(), 0.0f);
  }

  ~MonthlyHydroNetCDFOutput() {
    closeMonth();
  }

  void closeMonth() {
    riverVar = NcVar();
    storageVar = NcVar();
    outputFlowVar = NcVar();
    
    output.reset();
  }

  void openMonthForDay(unsigned absoluteDay) {
    int year = firstYear;
    int month = firstMonth;
    unsigned firstDayOfMonth = 0;
    
    while (true) {
      unsigned nDays = daysInMonth(year, month);
      
      if (absoluteDay < firstDayOfMonth + nDays) {
	currentYear = year;
	currentMonth = month;
	currentMonthFirstDay = firstDayOfMonth;
	currentMonthDays = nDays;
	break;
      }

      firstDayOfMonth += nDays;

      ++month;
      if (month == 13) {
	month = 1;
	++year;
      }
    }

    std::ostringstream filename;
    filename << outputDirectory;
    if (!outputDirectory.empty() &&
	outputDirectory[outputDirectory.size() - 1] != '/')
      filename << '/';
    
    filename << "hydronet_"
	     << currentYear << "_"
	     << std::setw(2) << std::setfill('0') << currentMonth
	     << ".nc4";

    output.reset(new NcFile(filename.str(), NcFile::replace));

    NcDim dayDim = output->addDim("day", currentMonthDays);
    NcDim latDim = output->addDim("latitude", nlat);
    NcDim lonDim = output->addDim("longitude", nlon);
    NcDim outputNodeDim = output->addDim("output_node", outputNodes.size());

    NcVar outLat = output->addVar("latitude", ncDouble, latDim);
    NcVar outLon = output->addVar("longitude", ncDouble, lonDim);
    
    outLat.putVar(lats.data());
    outLon.putVar(lons.data());

    // A continuous day index from the first simulation day.
    std::vector<int> times(currentMonthDays);
    for (unsigned d = 0; d < currentMonthDays; ++d)
      times[d] = static_cast<int>(currentMonthFirstDay + d);

    NcVar timeVar = output->addVar("day", ncInt, dayDim);
    timeVar.putVar(times.data());
    timeVar.putAtt("long_name", "simulation day index");
    timeVar.putAtt("units", "days since simulation start");
    
    riverVar = output->addVar("river_m3_day",
			      ncFloat,
			      std::vector<NcDim>{dayDim, latDim, lonDim});

    storageVar = output->addVar("stored_water_m3",
				ncFloat,
				std::vector<NcDim>{dayDim, latDim, lonDim});

    riverVar.putAtt("units", "m3 day-1");
    storageVar.putAtt("units", "m3");

    if (!outputNodes.empty()) {
      std::vector<double> outputLats(outputNodes.size());
      std::vector<double> outputLons(outputNodes.size());

      for (size_t i = 0; i < outputNodes.size(); ++i) {
	outputLats[i] = outputNodes[i]->getLatitude().getValue();
	outputLons[i] = outputNodes[i]->getLongitude().getValue();
      }

      NcVar outputLatVar =
	output->addVar("output_latitude", ncDouble, outputNodeDim);
      NcVar outputLonVar =
	output->addVar("output_longitude", ncDouble, outputNodeDim);

      outputLatVar.putVar(outputLats.data());
      outputLonVar.putVar(outputLons.data());

      outputLatVar.putAtt("units", "degrees_north");
      outputLonVar.putAtt("units", "degrees_east");

      outputFlowVar = output->addVar("output_m3_day",
				     ncFloat,
				     std::vector<NcDim>{dayDim, outputNodeDim});

      outputFlowVar.putAtt("long_name",
			   "daily routed discharge arriving at output node");
      outputFlowVar.putAtt("units", "m3 day-1");
      outputFlowVar.putAtt("coordinates",
			   "output_latitude output_longitude");
    }
  }

  void writeDay(
      unsigned day,
      const std::map<HydroNode*, double>& river_m3_day,
      const std::map<HydroNode*, double>& output_m3_day,
      const std::map<HydroNode*, double>& storage_m3_end_day) {

      if (!output || day < monthFirstDay || day >= monthFirstDay + monthDays) {
	closeMonth();
	openMonthForDay(day);
      }

      std::fill(riverValues.begin(), riverValues.end(), 0.0);
      std::fill(storageValues.begin(), storageValues.end(), 0.0);

      for (std::map<HydroNode*, double>::const_iterator it =
	     river_m3_day.begin();
	   it != river_m3_day.end(); ++it) {
	std::map<HydroNode*, size_t>::const_iterator pos =
	  riverGridIndex.find(it->first);
	
	if (pos != riverGridIndex.end() && std::isfinite(it->second))
	  riverValues[pos->second] += it->second;
      }

      for (std::map<HydroNode*, double>::const_iterator it =
	     storage_m3_end_day.begin();
	   it != storage_m3_end_day.end(); ++it) {
	std::map<HydroNode*, size_t>::const_iterator pos =
	  storageGridIndex.find(it->first);
	
	if (pos != storageGridIndex.end() && std::isfinite(it->second))
	  storageValues[pos->second] += it->second;
      }
      
      std::fill(outputFlowValues.begin(), outputFlowValues.end(), 0.0f);

      for (std::map<HydroOutputNode*, double>::const_iterator it =
	     output_m3_day.begin();
	   it != output_m3_day.end(); ++it) {
	std::map<HydroOutputNode*, size_t>::const_iterator pos =
	  outputNodeIndex.find(it->first);
	
	if (pos != outputNodeIndex.end() && std::isfinite(it->second))
	  outputFlowValues[pos->second] += static_cast<float>(it->second);
      }

      const size_t localDay = day - monthFirstDay;

      std::vector<size_t> start{localDay, 0, 0};
      std::vector<size_t> count{1, nlat, nlon};

      riverVar.putVar(start, count, riverValues.data());
      storageVar.putVar(start, count, storageValues.data());

      std::vector<size_t> outputStart{localDay, 0};
      std::vector<size_t> outputCount{1, outputNodes.size()};

      if (!outputNodes.empty())
	outputFlowVar.putVar(outputStart, outputCount, outputFlowValues.data());
  }
};

} // namespace openworld
