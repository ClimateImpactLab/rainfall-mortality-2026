#ifndef HYDRO_RUNNER_H
#define HYDRO_RUNNER_H

#include <map>
#include <vector>
#include <queue>
#include <set>
#include <list>
#include <cmath>
#include <algorithm>
#include <stdexcept>
#include <chrono>
#include <iostream>
#include <iomanip>
#include <string>

namespace openworld {

struct HydroForcing {
  virtual ~HydroForcing() {}

  virtual unsigned days() const = 0;
  
  // m/day at the surface node location.
  virtual double precipRunoff(HydroNode* node, unsigned day) = 0;
  virtual double meltRunoff(HydroNode* node, unsigned day) = 0;
};

struct HydroRunResult {
  // Daily totals, m3/day.
  map<HydroOutputNode*, vector<double> > output_m3_day;
  map<HydroNode*, vector<double> > river_m3_day;

  // Water present at the end of each day, m3.
  // Includes surface, hillslope/non-river, and river nodes.
  map<HydroNode*, vector<double> > storage_m3_end_day;
};

struct HydroDailyOutput {
  virtual ~HydroDailyOutput() {}

  virtual void writeDay(
      unsigned day,
      const std::map<HydroNode*, double>& river_m3_day,
      const std::map<HydroOutputNode*, double>& output_m3_day,
      const std::map<HydroNode*, double>& storage_m3_end_day) = 0;
};

class HydroRunner {
private:
  static constexpr double secondsPerDay = 86400.0;

  HydroNet& net;
  HydroForcing& forcing;
  unsigned ndays;
  unsigned substepsPerDay;

  set<HydroNode*> nodes;
  map<HydroNode*, double> storage_m3;

  void addDailySurfaceRunoff(unsigned day) {
    const map<unsigned, HydroNode*>& surfaces = net.getSurfaceNodes();

    for (map<unsigned, HydroNode*>::const_iterator it = surfaces.begin();
         it != surfaces.end(); ++it) {
      HydroNode* surface = it->second;
      if (surface == NULL)
        continue;

      double depth_m_day =
        forcing.precipRunoff(surface, day) +
        forcing.meltRunoff(surface, day);

      if (!std::isfinite(depth_m_day))
        depth_m_day = 0.0;

      if (depth_m_day < 0.0)
        depth_m_day = 0.0;

      storage_m3[surface] += depth_m_day * surface->getArea();
    }
  }

  void routeSubstep(std::map<HydroNode*, double>& riverToday,
		    std::map<HydroOutputNode*, double>& outputToday,
		    double dt_seconds) {
    map<HydroNode*, double> arrivals_m3;

    for (set<HydroNode*>::const_iterator it = nodes.begin();
         it != nodes.end(); ++it) {
      HydroNode* node = *it;

      if (node == NULL || node->isOutput())
        continue;

      double volume = storage_m3[node];
      if (volume <= 0.0)
        continue;

      double length_m = node->getDistAlong();
      if (length_m <= 0.0)
        continue;

      double velocity_m_s = node->calcVelocity(volume);
      if (!std::isfinite(velocity_m_s) || velocity_m_s <= 0.0)
        continue;

      // Fraction of this node's stored water that exits this substep.
      // Capped at 1 so a parcel crosses at most one node per substep.
      double travelFrac = velocity_m_s * dt_seconds / length_m;
      travelFrac = std::max(0.0, std::min(1.0, travelFrac));

      double out_m3 = volume * travelFrac;
      if (out_m3 <= 0.0)
        continue;

      storage_m3[node] -= out_m3;

      if (node->isRiver())
	riverToday[node] += out_m3;

      const list<pair<double, HydroNode*> >& edges = node->getEdges();

      for (list<pair<double, HydroNode*> >::const_iterator eit = edges.begin();
           eit != edges.end(); ++eit) {
        double weight = eit->first;
        HydroNode* dest = eit->second;

        if (dest == NULL || weight <= 0.0)
          continue;

        double routed_m3 = weight * out_m3;

        if (dest->isOutput()) {
          outputToday[static_cast<HydroOutputNode*>(dest)] += routed_m3;
        } else {
          arrivals_m3[dest] += routed_m3;
        }
      }
    }

    // Apply arrivals only after all nodes have routed for this substep.
    // This avoids iteration-order artifacts within a substep.
    for (map<HydroNode*, double>::const_iterator it = arrivals_m3.begin();
         it != arrivals_m3.end(); ++it) {
      storage_m3[it->first] += it->second;
    }
  }

  void reportProgress(unsigned completedDays,
		      const std::chrono::steady_clock::time_point& start) const {
    using namespace std::chrono;
    
    const unsigned barWidth = 40;

    double fraction = ndays > 0
      ? static_cast<double>(completedDays) / static_cast<double>(ndays)
      : 1.0;
    fraction = std::max(0.0, std::min(1.0, fraction));
  
    double elapsed =
      duration_cast<duration<double> >(steady_clock::now() - start).count();
    double remaining = fraction > 0.0
      ? elapsed * (1.0 / fraction - 1.0)
      : 0.0;
    
    unsigned filled = static_cast<unsigned>(std::round(fraction * barWidth));
    
    std::string bar(filled, '=');
    if (filled < barWidth)
      bar += '>';
    if (bar.size() < barWidth)
      bar += std::string(barWidth - bar.size(), ' ');
    
    std::cerr << "\rHydrology [" << bar << "] "
	      << std::fixed << std::setprecision(1)
	      << (100.0 * fraction) << "% "
	      << completedDays << "/" << ndays
	      << " | elapsed " << elapsed / 60.0 << " min"
	      << " | ETA " << remaining / 60.0 << " min"
	      << std::flush;
  }
  
public:
  HydroRunner(HydroNet& net,
              HydroForcing& forcing,
              unsigned ndays,
              unsigned substepsPerDay = 24)
    : net(net),
      forcing(forcing),
      ndays(ndays),
      substepsPerDay(substepsPerDay) {
    if (substepsPerDay == 0)
      throw std::runtime_error("HydroRunner: substepsPerDay must be positive.");

    nodes = net.collectReachableNodes();

    for (set<HydroNode*>::const_iterator it = nodes.begin();
         it != nodes.end(); ++it) {
      storage_m3[*it] = 0.0;
    }
  }

  void run(HydroDailyOutput& output) {
    std::chrono::steady_clock::time_point start =
      std::chrono::steady_clock::now();

    double dt_seconds = secondsPerDay / (double) substepsPerDay;

    for (unsigned day = 0; day < ndays; ++day) {
      addDailySurfaceRunoff(day);

      std::map<HydroNode*, double> riverToday;
      std::map<HydroOutputNode*, double> outputToday;

      for (unsigned sub = 0; sub < substepsPerDay; ++sub)
	routeSubstep(riverToday, outputToday, dt_seconds);

      // storage_m3 is already the end-of-day node state.
      output.writeDay(day, riverToday, outputToday, storage_m3);

      if (day == 0 || (day + 1) % 10 == 0 || day + 1 == ndays)
	reportProgress(day + 1, start);
    }

    std::cerr << std::endl;
  }
};

}

#endif	  
