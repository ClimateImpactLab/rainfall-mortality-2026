#ifndef NETCDF_HYDRO_FORCING_H
#define NETCDF_HYDRO_FORCING_H

#include <netcdf>
#include <string>
#include <vector>
#include <map>
#include <cmath>
#include <stdexcept>

namespace openworld {

class NetCDFHydroForcing : public HydroForcing {
private:
  netCDF::NcFile file;
  netCDF::NcVar precipVar;
  netCDF::NcVar meltVar;

  vector<double> ncLats;
  vector<double> ncLons;
  
  unsigned nday;
  unsigned nlat;
  unsigned nlon;

  // Assumes surface nodes align exactly with the NetCDF grid.
  // We cache node -> flat spatial index.
  map<HydroNode*, int> nodeIndex; // Use an invalid sentinel (-1) for nodes outside the regional coverage

  vector<double> precipDay;
  vector<double> meltDay;
  int loadedDay;

  static void checkVar(const netCDF::NcVar& var, const string& name) {
    if (var.isNull())
      throw std::runtime_error("Missing NetCDF variable: " + name);
  }

  void loadDay(unsigned day) {
    if ((int) day == loadedDay)
      return;

    if (day >= nday)
      throw std::runtime_error("NetCDFHydroForcing: day out of range.");

    vector<size_t> start;
    vector<size_t> count;

    start.push_back(day);
    start.push_back(0);
    start.push_back(0);

    count.push_back(1);
    count.push_back(nlat);
    count.push_back(nlon);

    precipVar.getVar(start, count, precipDay.data());
    meltVar.getVar(start, count, meltDay.data());

    loadedDay = (int) day;
  }

public:
  NetCDFHydroForcing(const string& path,
                     const string& precipRunoffVarName,
                     const string& meltRunoffVarName,
                     HydroNet& net)
    : file(path, netCDF::NcFile::read),
      loadedDay(-1) {
    precipVar = file.getVar(precipRunoffVarName);
    meltVar = file.getVar(meltRunoffVarName);

    checkVar(precipVar, precipRunoffVarName);
    checkVar(meltVar, meltRunoffVarName);

    vector<netCDF::NcDim> dims = precipVar.getDims();
    if (dims.size() != 3)
      throw std::runtime_error("Precip runoff variable must be day x lat x lon.");

    nday = dims[0].getSize();
    nlat = dims[1].getSize();
    nlon = dims[2].getSize();

    // Load regional coordinate vectors (assumes 1D lat and lon variables matching dim names)
    ncLats.resize(nlat);
    ncLons.resize(nlon);
    file.getVar("latitude").getVar(ncLats.data());
    file.getVar("longitude").getVar(ncLons.data());
    
    vector<netCDF::NcDim> mdims = meltVar.getDims();
    if (mdims.size() != 3 ||
        mdims[0].getSize() != nday ||
        mdims[1].getSize() != nlat ||
        mdims[2].getSize() != nlon)
      throw std::runtime_error("Melt runoff variable dimensions do not match precip runoff.");

    precipDay.assign(nlat * nlon, 0.0);
    meltDay.assign(nlat * nlon, 0.0);

    const map<unsigned, HydroNode*>& surfaces = net.getSurfaceNodes();

    for (map<unsigned, HydroNode*>::const_iterator it = surfaces.begin();
         it != surfaces.end(); ++it) {
      HydroNode* node = it->second;

      if (node == NULL)
        continue;

      int lat_idx = nearestGridIndex(ncLats, node->getLatitude().getValue());
      int lon_idx = nearestGridIndex(ncLons, node->getLongitude().getValue());

      if (lat_idx < 0 || lon_idx < 0)
	continue;

      nodeIndex[node] = lat_idx * static_cast<int>(nlon) + lon_idx;
    }

    std::cerr << "Mapped " << nodeIndex.size()
	 << " of " << surfaces.size()
	 << " surface nodes to forcing grid.\n";

    if (!nodeIndex.empty()) {
      HydroNode* node = nodeIndex.begin()->first;
      std::cerr << "First mapped node rainfall: "
		<< precipRunoff(node, 0) << "\n";
    }
  }

  unsigned days() const {
    return nday;
  }

  virtual double precipRunoff(HydroNode* node, unsigned day) {
    loadDay(day);

    auto it = nodeIndex.find(node);
    if (it == nodeIndex.end() || it->second < 0)
      return 0.0;
    
    double value = precipDay[it->second];
    if (!std::isfinite(value) || value < 0.0)
      return 0.0;

    return value;
  }

  virtual double meltRunoff(HydroNode* node, unsigned day) {
    loadDay(day);

    auto it = nodeIndex.find(node);
    if (it == nodeIndex.end() || it->second < 0)
      return 0.0;
    
    double value = meltDay[it->second];
    if (!std::isfinite(value) || value < 0.0)
      return 0.0;

    return value;
  }

  static int nearestGridIndex(const std::vector<double>& coords, double value) {
    if (coords.empty())
      return -1;

    bool ascending = coords.back() >= coords.front();

    auto compare = [ascending](double a, double b) {
      return ascending ? a < b : a > b;
    };

    auto pos = std::lower_bound(coords.begin(), coords.end(), value, compare);

    size_t candidate;
    if (pos == coords.begin()) {
      candidate = 0;
    } else if (pos == coords.end()) {
      candidate = coords.size() - 1;
    } else {
      size_t right = std::distance(coords.begin(), pos);
      size_t left = right - 1;
      candidate = std::abs(coords[left] - value) <=
	std::abs(coords[right] - value)
	? left : right;
    }

    double spacing = coords.size() > 1
      ? std::abs(coords[1] - coords[0])
      : 1.0;

    if (std::abs(coords[candidate] - value) > std::max(1e-8, spacing * 1e-6))
      return -1;

    return static_cast<int>(candidate);
  }

};

}

#endif
