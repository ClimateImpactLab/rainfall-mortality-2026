#ifndef MONTHLY_TEMPERATURE_HYDRO_FORCING_H
#define MONTHLY_TEMPERATURE_HYDRO_FORCING_H

/*
1. I have separate folders for tmax, tmin, and tp_total.
2. Within these folders are monthly files.
4. I want to construct the runoff variable as tp_total * Portion of the day above 0 C.
5. I want to construct the melt variable as a degree day factor * Degree days above 0 C, conditional on there beyond unmelted water.
6. I want to keep track of the amount of snow/ice water equivalent, as the running sum of tp_total * Portion of the day below 0 C minus degree day factor * Degree days above 0 C. This needs to be kept track of, so we don't apply the degree day melt when there's no standing snow/ice.
7. For our purpose, let's assume that the degree day factor is 3.5 mm °C⁻¹day⁻¹.
8. For both degree days and portion of the day above 0, I wan to apply a sinusoidal approximation between tmin and tmax.
*/

#include <netcdf>

#include <algorithm>
#include <cmath>
#include <cctype>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace openworld {

class MonthlyTemperatureHydroForcing : public HydroForcing {
private:
  static constexpr double DEGREE_DAY_FACTOR_MM = 3.5;
  static constexpr double MM_TO_M = 0.001;
  static constexpr double FREEZING_C = 0.0;

  struct Month {
    std::unique_ptr<netCDF::NcFile> precipFile;
    std::unique_ptr<netCDF::NcFile> tminFile;
    std::unique_ptr<netCDF::NcFile> tmaxFile;

    netCDF::NcVar precipVar;
    netCDF::NcVar tminVar;
    netCDF::NcVar tmaxVar;

    unsigned firstDay;
    unsigned nday;

    bool tminIsKelvin;
    bool tmaxIsKelvin;
  };

  struct NodeState {
    int gridIndex;

    // SWE in mm. stateDay is the first not-yet-processed day.
    unsigned stateDay;
    double sweMM;

    // Results for the most recently calculated day.
    int cachedDay;
    double cachedRainM;
    double cachedMeltM;

    NodeState()
      : gridIndex(-1),
        stateDay(0),
        sweMM(0.0),
        cachedDay(-1),
        cachedRainM(0.0),
        cachedMeltM(0.0) {}
  };

  std::vector<std::unique_ptr<Month> > months;

  std::vector<double> ncLats;
  std::vector<double> ncLons;

  unsigned nday;
  unsigned nlat;
  unsigned nlon;

  // Daily full-grid cache. float is appropriate because the source variables
  // are float and substantially reduces memory use for global ERA5 grids.
  std::vector<float> precipDay;
  std::vector<float> tminDay;
  std::vector<float> tmaxDay;
  int loadedDay;

  std::map<HydroNode*, NodeState> nodeStates;

  static void checkVar(const netCDF::NcVar& var, const std::string& name) {
    if (var.isNull())
      throw std::runtime_error("Missing NetCDF variable: " + name);
  }

  static bool isLeapYear(int year) {
    return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
  }

  static unsigned daysInMonth(int year, int month) {
    static const unsigned normal[] = {
      31, 28, 31, 30, 31, 30,
      31, 31, 30, 31, 30, 31
    };

    if (month < 1 || month > 12)
      throw std::runtime_error("Invalid month.");

    if (month == 2 && isLeapYear(year))
      return 29;

    return normal[month - 1];
  }

  static std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    return value;
  }

  static bool temperatureIsKelvin(const netCDF::NcVar& var,
                                  const std::string& name) {
    netCDF::NcVarAtt unitsAtt = var.getAtt("units");

    if (unitsAtt.isNull()) {
      throw std::runtime_error(
        "Temperature variable '" + name + "' has no units attribute.");
    }

    std::string units;
    unitsAtt.getValues(units);
    units = lower(units);

    if (units.find("kelvin") != std::string::npos ||
        units == "k") {
      return true;
    }

    if (units.find("celsius") != std::string::npos ||
        units.find("degc") != std::string::npos ||
        units.find("degree_c") != std::string::npos ||
        units == "c") {
      return false;
    }

    throw std::runtime_error(
      "Unrecognized temperature units for '" + name + "': " + units);
  }

  static std::string monthlyPath(const std::string& directory,
                                 const std::string& prefix,
                                 int year,
                                 int month) {
    std::ostringstream path;

    path << directory;
    if (!directory.empty() && directory[directory.size() - 1] != '/')
      path << '/';

    path << prefix << '_'
         << year << '_'
         << std::setw(2) << std::setfill('0') << month
         << ".nc4";

    return path.str();
  }

  static void checkCubeDimensions(const netCDF::NcVar& var,
                                  const std::string& name,
                                  unsigned expectedDays,
                                  unsigned expectedLat,
                                  unsigned expectedLon) {
    std::vector<netCDF::NcDim> dims = var.getDims();

    if (dims.size() != 3 ||
        dims[0].getSize() != expectedDays ||
        dims[1].getSize() != expectedLat ||
        dims[2].getSize() != expectedLon) {
      throw std::runtime_error(
        "Unexpected dimensions for variable '" + name +
        "'. Expected day x latitude x longitude.");
    }
  }

  static double clamp(double x, double lo, double hi) {
    return std::max(lo, std::min(x, hi));
  }

  /*
   * Fraction of a day above threshold, assuming:
   *
   *   T(t) = mean + amplitude * cos(2 pi t)
   *
   * The result is in [0, 1].
   */
  static double fractionAbove(double tminC, double tmaxC,
                              double threshold = FREEZING_C) {
    if (!std::isfinite(tminC) || !std::isfinite(tmaxC))
      return 0.0;

    if (tmaxC < tminC)
      std::swap(tminC, tmaxC);

    if (tminC >= threshold)
      return 1.0;

    if (tmaxC <= threshold)
      return 0.0;

    double mean = 0.5 * (tminC + tmaxC);
    double amplitude = 0.5 * (tmaxC - tminC);

    if (amplitude <= 0.0)
      return mean > threshold ? 1.0 : 0.0;

    double x = clamp((threshold - mean) / amplitude, -1.0, 1.0);
    double alpha = std::acos(x);

    return alpha / M_PI;
  }

  /*
   * Integral over one day of max(T(t) - threshold, 0), in deg C day.
   */
  static double degreeDaysAbove(double tminC, double tmaxC,
                                double threshold = FREEZING_C) {
    if (!std::isfinite(tminC) || !std::isfinite(tmaxC))
      return 0.0;

    if (tmaxC < tminC)
      std::swap(tminC, tmaxC);

    if (tmaxC <= threshold)
      return 0.0;

    double mean = 0.5 * (tminC + tmaxC);
    double amplitude = 0.5 * (tmaxC - tminC);

    if (tminC >= threshold)
      return std::max(0.0, mean - threshold);

    if (amplitude <= 0.0)
      return std::max(0.0, mean - threshold);

    double x = clamp((threshold - mean) / amplitude, -1.0, 1.0);
    double alpha = std::acos(x);

    // Equivalent to the R sinusoidal integration calculation.
    return std::max(
      0.0,
      (amplitude * std::sin(alpha) +
       (mean - threshold) * alpha) / M_PI
    );
  }

  static double toCelsius(float value, bool isKelvin) {
    if (!std::isfinite(value))
      return std::numeric_limits<double>::quiet_NaN();

    return isKelvin ? static_cast<double>(value) - 273.15
                    : static_cast<double>(value);
  }

  void loadDay(unsigned day) {
    if (static_cast<int>(day) == loadedDay)
      return;

    if (day >= nday)
      throw std::runtime_error(
        "MonthlyTemperatureHydroForcing: day out of range.");

    Month* selected = NULL;

    for (std::size_t i = 0; i < months.size(); ++i) {
      Month* month = months[i].get();

      if (day >= month->firstDay &&
          day < month->firstDay + month->nday) {
        selected = month;
        break;
      }
    }

    if (selected == NULL)
      throw std::runtime_error("Could not find monthly forcing file for day.");

    unsigned localDay = day - selected->firstDay;

    std::vector<size_t> start(3);
    std::vector<size_t> count(3);

    start[0] = localDay;
    start[1] = 0;
    start[2] = 0;

    count[0] = 1;
    count[1] = nlat;
    count[2] = nlon;

    selected->precipVar.getVar(start, count, precipDay.data());
    selected->tminVar.getVar(start, count, tminDay.data());
    selected->tmaxVar.getVar(start, count, tmaxDay.data());

    loadedDay = static_cast<int>(day);
  }

  /*
   * Advance one node through all necessary days, storing the requested day's
   * rainfall and melt outputs in its cache.
   */
  void advanceNodeToDay(NodeState& state, unsigned targetDay) {
    // If callers request days out of chronological order, recompute this
    // node's snow state from the beginning. Normal simulations will request
    // days monotonically, so this branch is normally never used.
    if (targetDay < state.stateDay) {
      state.stateDay = 0;
      state.sweMM = 0.0;
      state.cachedDay = -1;
      state.cachedRainM = 0.0;
      state.cachedMeltM = 0.0;
    }

    while (state.stateDay <= targetDay) {
      unsigned day = state.stateDay;
      loadDay(day);

      std::size_t idx = static_cast<std::size_t>(state.gridIndex);

      double precipitationMM = static_cast<double>(precipDay[idx]);
      if (!std::isfinite(precipitationMM) || precipitationMM < 0.0)
        precipitationMM = 0.0;

      Month* currentMonth = NULL;
      for (std::size_t i = 0; i < months.size(); ++i) {
        Month* month = months[i].get();
        if (day >= month->firstDay &&
            day < month->firstDay + month->nday) {
          currentMonth = month;
          break;
        }
      }

      if (currentMonth == NULL)
        throw std::runtime_error("Internal monthly forcing lookup failure.");

      double tminC = toCelsius(tminDay[idx], currentMonth->tminIsKelvin);
      double tmaxC = toCelsius(tmaxDay[idx], currentMonth->tmaxIsKelvin);

      double liquidFraction = fractionAbove(tminC, tmaxC);
      double degreeDays = degreeDaysAbove(tminC, tmaxC);

      double rainMM = precipitationMM * liquidFraction;
      double snowMM = precipitationMM * (1.0 - liquidFraction);

      // New snowfall is available for melting on the same modeled day.
      state.sweMM += snowMM;

      double potentialMeltMM = DEGREE_DAY_FACTOR_MM * degreeDays;
      double actualMeltMM = std::min(state.sweMM, potentialMeltMM);

      state.sweMM -= actualMeltMM;
      if (state.sweMM < 0.0)
        state.sweMM = 0.0;

      state.cachedDay = static_cast<int>(day);
      state.cachedRainM = rainMM * MM_TO_M;
      state.cachedMeltM = actualMeltMM * MM_TO_M;

      ++state.stateDay;
    }
  }

public:
  /*
   * prefix examples:
   *
   *   precipPrefix = "era5land_global_tp_total"
   *   tminPrefix   = "era5land_global_tmin"
   *   tmaxPrefix   = "era5land_global_tmax"
   *
   * The inclusive date range determines which monthly files are opened.
   */
  MonthlyTemperatureHydroForcing(
      const std::string& precipDirectory,
      const std::string& tminDirectory,
      const std::string& tmaxDirectory,
      const std::string& precipPrefix,
      const std::string& tminPrefix,
      const std::string& tmaxPrefix,
      const std::string& precipVarName,
      const std::string& tminVarName,
      const std::string& tmaxVarName,
      int firstYear,
      int firstMonth,
      int lastYear,
      int lastMonth,
      HydroNet& net)
    : nday(0),
      nlat(0),
      nlon(0),
      loadedDay(-1) {

    if (firstYear > lastYear ||
        (firstYear == lastYear && firstMonth > lastMonth)) {
      throw std::runtime_error("Invalid forcing date range.");
    }

    bool firstFile = true;

    int year = firstYear;
    int month = firstMonth;

    while (year < lastYear ||
           (year == lastYear && month <= lastMonth)) {

      std::unique_ptr<Month> entry(new Month());

      std::string precipPath =
        monthlyPath(precipDirectory, precipPrefix, year, month);
      std::string tminPath =
        monthlyPath(tminDirectory, tminPrefix, year, month);
      std::string tmaxPath =
        monthlyPath(tmaxDirectory, tmaxPrefix, year, month);

      entry->precipFile.reset(
        new netCDF::NcFile(precipPath, netCDF::NcFile::read));
      entry->tminFile.reset(
        new netCDF::NcFile(tminPath, netCDF::NcFile::read));
      entry->tmaxFile.reset(
        new netCDF::NcFile(tmaxPath, netCDF::NcFile::read));

      entry->precipVar = entry->precipFile->getVar(precipVarName);
      entry->tminVar = entry->tminFile->getVar(tminVarName);
      entry->tmaxVar = entry->tmaxFile->getVar(tmaxVarName);

      checkVar(entry->precipVar, precipVarName);
      checkVar(entry->tminVar, tminVarName);
      checkVar(entry->tmaxVar, tmaxVarName);

      std::vector<netCDF::NcDim> precipDims = entry->precipVar.getDims();

      if (precipDims.size() != 3)
        throw std::runtime_error(
          "Precipitation must have dimensions valid_time x latitude x longitude.");

      unsigned monthDays = precipDims[0].getSize();
      unsigned monthLat = precipDims[1].getSize();
      unsigned monthLon = precipDims[2].getSize();

      if (monthDays != daysInMonth(year, month)) {
        throw std::runtime_error(
          "Unexpected number of daily records in " + precipPath);
      }

      if (firstFile) {
        nlat = monthLat;
        nlon = monthLon;

        ncLats.resize(nlat);
        ncLons.resize(nlon);

        netCDF::NcVar latVar = entry->precipFile->getVar("latitude");
        netCDF::NcVar lonVar = entry->precipFile->getVar("longitude");

        checkVar(latVar, "latitude");
        checkVar(lonVar, "longitude");

        latVar.getVar(ncLats.data());
        lonVar.getVar(ncLons.data());

        firstFile = false;
      } else if (monthLat != nlat || monthLon != nlon) {
        throw std::runtime_error(
          "Forcing grid dimensions differ between monthly files.");
      }

      checkCubeDimensions(
        entry->tminVar, tminVarName, monthDays, nlat, nlon);
      checkCubeDimensions(
        entry->tmaxVar, tmaxVarName, monthDays, nlat, nlon);

      entry->firstDay = nday;
      entry->nday = monthDays;
      entry->tminIsKelvin = temperatureIsKelvin(entry->tminVar, tminVarName);
      entry->tmaxIsKelvin = temperatureIsKelvin(entry->tmaxVar, tmaxVarName);

      nday += monthDays;
      months.push_back(std::move(entry));

      ++month;
      if (month == 13) {
        month = 1;
        ++year;
      }
    }

    std::size_t ncell =
      static_cast<std::size_t>(nlat) * static_cast<std::size_t>(nlon);

    precipDay.assign(ncell, 0.0f);
    tminDay.assign(ncell, 0.0f);
    tmaxDay.assign(ncell, 0.0f);

    const std::map<unsigned, HydroNode*>& surfaces = net.getSurfaceNodes();

    for (std::map<unsigned, HydroNode*>::const_iterator it = surfaces.begin();
         it != surfaces.end(); ++it) {
      HydroNode* node = it->second;

      if (node == NULL)
        continue;

      double latitude = node->getLatitude().getValue();
      double longitude = node->getLongitude().getValue();

      // Accommodate a node grid using [-180, 180) longitudes when ERA5 is
      // represented as [0, 360).
      if (!ncLons.empty() && ncLons.front() >= 0.0 && longitude < 0.0)
        longitude += 360.0;

      int latIndex = nearestGridIndex(ncLats, latitude);
      int lonIndex = nearestGridIndex(ncLons, longitude);

      if (latIndex < 0 || lonIndex < 0)
        continue;

      NodeState state;
      state.gridIndex =
        latIndex * static_cast<int>(nlon) + lonIndex;

      nodeStates[node] = state;
    }

    std::cerr << "Mapped " << nodeStates.size()
              << " of " << surfaces.size()
              << " surface nodes to monthly forcing grid.\n";
  }

  virtual unsigned days() const {
    return nday;
  }

  virtual double precipRunoff(HydroNode* node, unsigned day) {
    std::map<HydroNode*, NodeState>::iterator it = nodeStates.find(node);

    if (it == nodeStates.end())
      return 0.0;

    advanceNodeToDay(it->second, day);

    return it->second.cachedDay == static_cast<int>(day)
      ? it->second.cachedRainM
      : 0.0;
  }

  virtual double meltRunoff(HydroNode* node, unsigned day) {
    std::map<HydroNode*, NodeState>::iterator it = nodeStates.find(node);

    if (it == nodeStates.end())
      return 0.0;

    advanceNodeToDay(it->second, day);

    return it->second.cachedDay == static_cast<int>(day)
      ? it->second.cachedMeltM
      : 0.0;
  }

  static int nearestGridIndex(const std::vector<double>& coords,
                              double value) {
    if (coords.empty())
      return -1;

    bool ascending = coords.back() >= coords.front();

    std::vector<double>::const_iterator pos =
      std::lower_bound(
        coords.begin(), coords.end(), value,
        [ascending](double a, double b) {
          return ascending ? a < b : a > b;
        });

    std::size_t candidate;

    if (pos == coords.begin()) {
      candidate = 0;
    } else if (pos == coords.end()) {
      candidate = coords.size() - 1;
    } else {
      std::size_t right =
        static_cast<std::size_t>(std::distance(coords.begin(), pos));
      std::size_t left = right - 1;

      candidate =
        std::abs(coords[left] - value) <= std::abs(coords[right] - value)
        ? left
        : right;
    }

    double spacing = coords.size() > 1
      ? std::abs(coords[1] - coords[0])
      : 1.0;

    // Retains the original class's "must align with the forcing grid"
    // interpretation, while allowing floating-point coordinate noise.
    if (std::abs(coords[candidate] - value) >
        std::max(1e-8, spacing * 1e-6)) {
      return -1;
    }

    return static_cast<int>(candidate);
  }
};

} // namespace openworld

#endif
