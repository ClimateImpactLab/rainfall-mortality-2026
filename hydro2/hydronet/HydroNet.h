#ifndef HYDRONET_H
#define HYDRONET_H

#include <float.h>
#include <fstream>
#include <cassert>
#include <utils/ToString.h>
#include <memory/SerializationTools.h>
#include <list>
#include <queue>
#include <measure/Measure.h>
#include <datastr/GeographicMap.h>
#include <tools/hydro/DInfinityMap.h>

using namespace std;

namespace openworld {
  void* nodeListConstructor(istream& in, PointerReference& reference);
  void* hydronodeConstructor(istream& in, PointerReference& reference);

  class HydroNode : public IPointerSerializable {
  protected:
    // structural
    list< pair<double, HydroNode*> > edges;

    double nodeArea;
    double distAlong;
    double distAcross;
    double slope;
    double minToFlow;
    double maxVelocity;

    // meta-data
    Measure latitude;
    Measure longitude;

    HydroNode(double nodeArea, double distAlong, double distAcross, double slope, double minToFlow, double maxVelocity, Measure latitude, Measure longitude)
      : latitude(latitude), longitude(longitude) {
      this->nodeArea = nodeArea;
      this->distAlong = distAlong;
      this->distAcross = distAcross;
      this->slope = slope;
      this->minToFlow = minToFlow;
      this->maxVelocity = maxVelocity;
    }

  public:
    virtual HydroNode* clone(map<HydroNode*, HydroNode*>& translate, list<HydroNode*>& created) = 0;

    virtual ~HydroNode() {}
    
    Measure getLatitude() {
      return latitude;
    }

    Measure getLongitude() {
      return longitude;
    }

    const list<pair<double, HydroNode*> >& getEdges() const {
      return edges;
    }

    double getArea() const { return nodeArea; }
    double getDistAlong() const { return distAlong; }
    double getMinToFlow() const { return minToFlow; }

    virtual double calcVelocity(double volume) const = 0;
    virtual bool isOutput() const { return false; }
    virtual bool isRiver() const { return false; }

    bool matchLocation(HydroNode* other) {
      return (latitude == other->latitude && longitude == other->longitude);
    }

    static void replaceNode(HydroNode* oldnode, HydroNode* newnode, map<unsigned, HydroNode*>& surfaces_coarse) {
      for (map<unsigned, HydroNode*>::const_iterator it = surfaces_coarse.begin(); it != surfaces_coarse.end(); it++)
	replaceNode(oldnode, newnode, it->second);
    }
    
    static void replaceNode(HydroNode* oldnode, HydroNode* newnode, HydroNode *search) {
      list< pair<double, HydroNode*> >::iterator it;
      for (it = search->edges.begin(); it != search->edges.end(); it++) {
	if (it->second == oldnode)
	  it->second = newnode;
	else
	  replaceNode(oldnode, newnode, it->second);
      }
    }

    // ignore keys of map
    void setEdges(map<unsigned, pair<double, HydroNode*> >& edges, double divide = 1.0) {
      this->edges.clear();
      if (divide == 0)
        return;

      double total = 0;
      map<unsigned, pair<double, HydroNode*> >::iterator it;
      for (it = edges.begin(); it != edges.end(); it++) {
        this->edges.push_back(pair<double, HydroNode*>(it->second.first / divide, it->second.second));
        total += it->second.first / divide;
      }

      if (total < 1.0 - FLT_EPSILON * edges.size() || total > 1.0 + FLT_EPSILON * edges.size())
        throw runtime_error("Edges do not sum to 1: " + ToString::flong(total) + " for " + ToString::base10(divide));
    }

    // Slope is drop / run
    static double calcManning(double coeff, double radius, double slope) {
      if (radius <= 0 || slope <= 0)
        return 0.0;
      double vel = (1 / coeff) * pow(radius, 2.0/3.0) * sqrt(slope);

      return vel;
    }

    // From "Simpliﬁed versions for the Penman evaporation equation using routine weather data" by Valiantzas, 2006
    // temp in C, relhum between 0 and 1, light between 0 and 1 (portion of daylight hours light), lat in degrees, month = 1 for jan
    // the result is mm/day
    static double calcEvaporation(double temp, double relhum, double light, Measure lat, int month) {
      return 11.63 * exp(0.077 * temp) / 30;
    }

    void translateEdges(HydroNode& copy, map<HydroNode*, HydroNode*>& translate, list<HydroNode*>& created) {
      edges.clear();

      for (list< pair<double, HydroNode*> >::iterator it = copy.edges.begin(); it != copy.edges.end(); it++)
        edges.push_back(pair<double, HydroNode*>(it->first, HydroNode::getCopy(it->second, translate, created)));
    }

    static HydroNode* getCopy(HydroNode* node, map<HydroNode*, HydroNode*>& translate, list<HydroNode*>& created) {
      map<HydroNode*, HydroNode*>::iterator it = translate.find(node);
      if (it != translate.end())
        return it->second;

      HydroNode* copy = node->clone(translate, created);
      translate[node] = copy;
      created.push_back(copy);

      return copy;
    }

    // Serializable protocol

    virtual ostream& streamInsert(ostream& os, PointerTracker& tracker) const {
      latitude.streamInsert(os) << " ";
      longitude.streamInsert(os) << " ";
      os << nodeArea << " " << distAlong << " " <<
	distAcross << " " << slope << " " << minToFlow << " " << maxVelocity << endl;
      os << edges.size() << endl;
      for (list< pair<double, HydroNode*> >::const_iterator it = edges.begin(); it != edges.end(); it++) {
	os << it->first << " ";
	if (tracker.streamInsertPointer(os, it->second))
	  it->second->streamInsert(os, tracker);
      }
      return os;
    }

    virtual istream& streamExtract(istream& in, PointerReference& reference) {
      latitude = Measure::streamExtract(in);
      longitude = Measure::streamExtract(in);
      in >> nodeArea >> distAlong >>
	distAcross >> slope >> minToFlow >> maxVelocity;

      uint size;
      double first;
      in >> size;
      edges.clear();
      for (uint ii = 0; ii < size; ii++) {
	in >> first;
	HydroNode* second = (HydroNode*) reference.streamExtractPointer(in, hydronodeConstructor);
	edges.push_back(pair<double, HydroNode*>(first, second));
      }
      return in;
    }

    static void* streamExtractPointer(istream& in, PointerReference& reference) {
	throw logic_error("HydroNode::streamExtractPointer not implemented; use hydronodeConstructor.");
    }
  };

  class HydroSurfaceNode : public HydroNode {
  private:
    static const double minSurfaceToFlow;
    static const double maxSurfaceVelocity;

  public:
    HydroSurfaceNode(double nodeArea, double distAlong, double distAcross, double slope,
		     Measure latitude, Measure longitude)
      : HydroNode(nodeArea, distAlong, distAcross, slope, minSurfaceToFlow, maxSurfaceVelocity, latitude, longitude) {
    }

    virtual HydroNode* clone(map<HydroNode*, HydroNode*>& translate, list<HydroNode*>& created) {
      HydroNode* copy = new HydroSurfaceNode(*this);
      copy->translateEdges(*this, translate, created);

      return copy;
    }

    virtual double calcEvaporationRate(GeographicMap<double>& temps, GeographicMap<double>& snowCover, GeographicMap<double>& relhums, GeographicMap<double>& lights, double fracyear, double surfaceEvaporationFactor, double riverEvaporationFactor) {
      double evapRate = HydroNode::calcEvaporation(temps.getDouble(latitude, longitude) - 273.15, relhums.getDouble(latitude, longitude), lights.getDouble(latitude, longitude), latitude, max(fracyear * 12 + 1, 12.0));
      return surfaceEvaporationFactor * evapRate * (1.0 - snowCover.getDouble(latitude, longitude));
    }

    double calcVelocity(double volume) const {
      if (volume < minToFlow)
        return 0;

      double height = volume / nodeArea;
      double vel = calcManning(.025, height, max(height / (2 * distAlong), slope));
      return min(vel, maxVelocity); //90 * sqrt(height / 2)); //(water terminal velocity)
    }

    // Serializable protocol

    virtual ostream& streamInsert(ostream& os, PointerTracker& tracker) const {
      os << "HydroSurfaceNode" << endl;
      HydroNode::streamInsert(os, tracker);
      return os;
    }

    virtual istream& streamExtract(istream& in, PointerReference& reference) {
      return HydroNode::streamExtract(in, reference);
    }

    static void* streamExtractPointer(istream& in, PointerReference& reference) {
      HydroSurfaceNode* node = new HydroSurfaceNode(0., 0., 0., 0., Measure(0., Inds::lat), Measure(0., Inds::lon));
      node->streamExtract(in, reference);
      return node;
    }
  };

  class HydroRiverNode : public HydroNode  {
  private:
    static const double minRiverToFlow;
    static const double maxRiverVelocity;

  public:
    HydroRiverNode(double nodeArea, double distAlong, double distAcross, double slope,
		   Measure latitude, Measure longitude)
      : HydroNode(nodeArea, distAlong, distAcross, slope, minRiverToFlow, maxRiverVelocity, latitude, longitude) {
    }

    virtual HydroNode* clone(map<HydroNode*, HydroNode*>& translate, list<HydroNode*>& created) {
      HydroNode* copy = new HydroRiverNode(*this);
      copy->translateEdges(*this, translate, created);

      return copy;
    }

    virtual double calcEvaporationRate(GeographicMap<double>& temps, GeographicMap<double>& snowCover, GeographicMap<double>& relhums, GeographicMap<double>& lights, double fracyear, double surfaceEvaporationFactor, double riverEvaporationFactor) {
      return riverEvaporationFactor * HydroNode::calcEvaporation(temps.getDouble(latitude, longitude) - 273.15, relhums.getDouble(latitude, longitude), lights.getDouble(latitude, longitude), latitude, max(fracyear * 12 + 1, 12.0));
    }

    double calcRiverWidth(double volume) const {
      return 2 * sqrt((3 / M_PI) * volume / distAlong);
    }

    double calcVelocity(double volume) const {
      if (volume < minToFlow)
        return 0;

      // 1/3 of circle calculation
      double width = calcRiverWidth(volume);
      if (width <= 0)
        return 0;

      double r, height;
      if (width > distAcross) {
        r = volume / nodeArea;
        height = r;
      } else {
        r = (volume / distAlong) / (M_PI * width / 3);
        height = width / 2;
      }

      double vel = calcManning(.033, r, max(height / (2 * distAlong), slope));
      return min(vel, maxVelocity); //90 * sqrt(height)); // terminal velocity
    }

    bool isRiver() const { return true; }

    // Serializable protocol

    virtual ostream& streamInsert(ostream& os, PointerTracker& tracker) const {
      os << "HydroRiverNode" << endl;
      HydroNode::streamInsert(os, tracker);
      return os;
    }

    virtual istream& streamExtract(istream& in, PointerReference& reference) {
      return HydroNode::streamExtract(in, reference);
    }

    static void* streamExtractPointer(istream& in, PointerReference& reference) {
      HydroRiverNode* node = new HydroRiverNode(0., 0., 0., 0., Measure(0., Inds::lat), Measure(0., Inds::lon));
      node->streamExtract(in, reference);
      return node;
    }
  };

  class HydroOutputNode : public HydroNode  {
  public:
    HydroOutputNode(double lat, double lon)
      : HydroNode(0, 0, 0, 0, 0, 0, Measure(lat, Inds::lat), Measure(lon, Inds::lon)) {
    }

    virtual HydroNode* clone(map<HydroNode*, HydroNode*>& translate, list<HydroNode*>& created) {
      HydroNode* copy = new HydroOutputNode(*this);
      copy->translateEdges(*this, translate, created);

      return copy;
    }

    virtual double calcEvaporationRate(GeographicMap<double>& temps, GeographicMap<double>& snowCover, GeographicMap<double>& relhums, GeographicMap<double>& lights, double fracyear, double surfaceEvaporationFactor, double riverEvaporationFactor) {
      return 0;
    }

    double calcVelocity(double volume) const {
      return 0;
    }

    bool isOutput() const { return true; }

    // Serialization

    virtual ostream& streamInsert(ostream& os, PointerTracker& tracker) const {
      os << "HydroOutputNode" << endl;
      HydroNode::streamInsert(os, tracker);
      return os;
    }

    virtual istream& streamExtract(istream& in, PointerReference& reference) {
      HydroNode::streamExtract(in, reference);
      return in;
    }

    static void* streamExtractPointer(istream& in, PointerReference& reference) {
      HydroOutputNode* node = new HydroOutputNode(0., 0.);
      node->streamExtract(in, reference);
      return node;
    }

  };

  class HydroNet {
  protected:
    GeographicMap<double> mask_coarse;
    map<unsigned, HydroNode*> surfaces_coarse; // mask_coarse index -> surface node

    // List of nodes created (currently just during copy)
    list<HydroNode*> created;
    
  public:
    HydroNet(GeographicMap<double>& mask_coarse)
      : mask_coarse(mask_coarse) {
    }

    HydroNet(HydroNet& copy, map<HydroNode*, HydroNode*>& translate)
      : mask_coarse(copy.mask_coarse) {

      for (map<unsigned, HydroNode*>::iterator it = copy.surfaces_coarse.begin(); it != copy.surfaces_coarse.end(); it++) {
        surfaces_coarse[it->first] = HydroNode::getCopy(it->second, translate, created);
      }
    }

    virtual ~HydroNet() {
      for (list<HydroNode*>::iterator lit = created.begin(); lit != created.end(); lit++)
	delete *lit;
    }

    GeographicMap<double>& getMaskCoarse() {
      return mask_coarse;
    }
    
    map<unsigned, HydroNode*>& getSurfaceNodes() {
      return surfaces_coarse;
    }
    
    HydroOutputNode* test(DInfinityMap& direction_fine) {
      return NULL;
    }

    set<HydroNode*> collectReachableNodes() {
      set<HydroNode*> seen;
      queue<HydroNode*> pending;

      const map<unsigned, HydroNode*>& surfaces = getSurfaceNodes();
      for (map<unsigned, HydroNode*>::const_iterator it = surfaces.begin();
	   it != surfaces.end(); ++it) {
	if (it->second != NULL)
	  pending.push(it->second);
      }

      while (!pending.empty()) {
	HydroNode* node = pending.front();
	pending.pop();
	
	if (node == NULL || seen.count(node))
	  continue;

	seen.insert(node);

	const list<pair<double, HydroNode*> >& edges = node->getEdges();
	for (list<pair<double, HydroNode*> >::const_iterator eit = edges.begin();
	     eit != edges.end(); ++eit) {
	  if (eit->second != NULL && !seen.count(eit->second))
	    pending.push(eit->second);
	}
      }
      
      return seen;
    }

    void generate(DInfinityMap& direction_fine, GeographicMap<bool>& mask_fine, GeographicMap<double>& slope_fine, double min_dist, vector<HydroOutputNode*> outputNodes) {
      HydroOutputNode* outside = new HydroOutputNode(0., 0.);
      HydroOutputNode* ignore = new HydroOutputNode(0., 0.);

      map<unsigned, HydroNode*> rivers;

      surfaces_coarse.clear();

      // Loop over all surface cells
      for (unsigned rr = 0; rr < mask_coarse.getLatitudes().count(); rr++)
        for (unsigned cc = 0; cc < mask_coarse.getLongitudes().count(); cc++) {
	  if (mask_coarse.getCellConst(rr, cc) < 0.5)
	    continue;
          cout << "Generating cell " << rr << ", " << cc << endl;

          HydroNode* surface = generateSurfaceNode(rr, cc, outputNodes, outside, ignore, rivers, direction_fine, mask_fine, slope_fine, min_dist);
	  
          surfaces_coarse[mask_coarse.getIndex(rr, cc)] = surface;
        }
    }

    void generateSurfaceNodeFiles(DInfinityMap& direction_fine, GeographicMap<bool>& mask_fine, GeographicMap<double>& slope_fine, double min_dist, vector<HydroOutputNode*> outputNodes) {
      surfaces_coarse.clear();

      // Loop over all surface cells
      for (unsigned rr = 0; rr < mask_coarse.getLatitudes().count(); rr++)
        for (unsigned cc = 0; cc < mask_coarse.getLongitudes().count(); cc++) {
	  std::ifstream file("coarse-" + std::to_string(rr) + "-" + std::to_string(cc) + ".dat");
	  if (file.good())
	    continue;
          cout << "Generating cell " << rr << ", " << cc << endl;

	  HydroOutputNode* outside = new HydroOutputNode(0., 0.);
	  HydroOutputNode* ignore = new HydroOutputNode(0., 0.);
	  
	  map<unsigned, HydroNode*> rivers;

          HydroNode* surface = generateSurfaceNode(rr, cc, outputNodes, outside, ignore, rivers, direction_fine, mask_fine, slope_fine, min_dist);

	  std::ofstream binaryFile("coarse-" + std::to_string(rr) + "-" + std::to_string(cc) + ".dat", std::ios::binary);
	  PointerTracker tracker;
	  surface->streamInsert(binaryFile, tracker);
	  streamInsertVector(outputNodes, binaryFile, tracker);
	  outside->streamInsert(binaryFile, tracker);
	  ignore->streamInsert(binaryFile, tracker);
	  binaryFile << endl;
	  binaryFile.close();
        }
    }

    void generateFromSurfaceNodeFiles(vector<HydroOutputNode*> outputNodes) {
      map<unsigned, HydroNode*> rivers;

      surfaces_coarse.clear();

      // Loop over all surface cells
      for (unsigned rr = 0; rr < mask_coarse.getLatitudes().count(); rr++)
        for (unsigned cc = 0; cc < mask_coarse.getLongitudes().count(); cc++) {
	  cout << rr << ", " << cc << endl;
	  std::ifstream binaryFile("coarse-" + std::to_string(rr) + "-" + std::to_string(cc) + ".dat", std::ios::binary);
	  if (!binaryFile.good()) {
	    cout << "Missing file!" << endl;
	    continue;
	  }
	  
	  PointerReference tracker;

	  string subclass;
	  getline(binaryFile, subclass);
	  assert(subclass == "HydroSurfaceNode");

	  HydroNode* surface = (HydroNode*) HydroSurfaceNode::streamExtractPointer(binaryFile, tracker);
	  vector<HydroOutputNode*> tileOutputNodes;
	  streamExtractVector(binaryFile, tracker, tileOutputNodes, HydroOutputNode::streamExtractPointer);

	  mergeByLocation(outputNodes, tileOutputNodes, surfaces_coarse);
	  
	  binaryFile.close();
	  
          surfaces_coarse[mask_coarse.getIndex(rr, cc)] = surface;
        }
    }

    HydroSurfaceNode* generateSurfaceNode(unsigned rr, unsigned cc, const vector<HydroOutputNode*>& outputNodes, HydroOutputNode* outside, HydroOutputNode* ignore, map<unsigned, HydroNode*>& rivers, DInfinityMap& direction_fine, GeographicMap<bool>& mask_fine, GeographicMap<double>& slope_fine, double min_dist) {
      double total_dist = 0, total_slope = 0, weight_slope = 0;
      unsigned paths = 0;

      map<unsigned, pair<double, HydroNode*> > edges;

      // Loop over all elevation cells within
      for (Measure lat = mask_coarse.getLatitudes().getCellMin(rr) + mask_fine.getLatitudes().getWidths() / 3;
	   lat < mask_coarse.getLatitudes().getCellMax(rr); lat += mask_fine.getLatitudes().getWidths())
	for (Measure lon = mask_coarse.getLongitudes().getCellMin(cc) + mask_fine.getLongitudes().getWidths() / 3;
	     lon < mask_coarse.getLongitudes().getCellMax(cc); lon += mask_fine.getLongitudes().getWidths()) {

	  // cout << mask_fine.getDouble(lat, lon) << endl;
	  if (lat < mask_fine.getLatitudes().getMin() || lat >= mask_fine.getLatitudes().getMax() ||
	      lon < mask_fine.getLongitudes().getMin() || lon >= mask_fine.getLongitudes().getMax() ||
	      mask_fine.getDouble(lat, lon) == 0)
	    continue;

	  paths++;
	  
	  // Follow this out of the cell
	  queue< pair< pair<Measure, Measure>, double> > pending;
	  pending.push(pair< pair<Measure, Measure>, double>(pair<Measure, Measure>(lat, lon), 1.0));

	  while (!pending.empty()) {
	    pair< pair<Measure, Measure>, double> llp = pending.front();
	    pair<Measure, Measure> ll = llp.first;
	    if (ll.first < mask_coarse.getLatitudes().getCellMin(rr) ||
		ll.first >= mask_coarse.getLatitudes().getCellMax(rr) ||
		ll.second < mask_coarse.getLongitudes().getCellMin(cc) ||
		ll.second >= mask_coarse.getLongitudes().getCellMax(cc)) {
	      // connect this to the river out
	      if (rivers.find(mask_fine.getIndex(ll.first, ll.second)) == rivers.end()) {
		generateRiver(ll.first, ll.second, rivers, direction_fine, mask_fine, slope_fine, outputNodes, outside, ignore, min_dist);
	      }
	      
	      addEdge(edges, mask_fine.getIndex(ll.first, ll.second), llp.second, rivers[mask_fine.getIndex(ll.first, ll.second)]);
	    } else {
	      total_dist += llp.second * mask_fine.calcCellSpan(lat, lon);
	      total_slope += llp.second * slope_fine.getDouble(lat, lon);
	      weight_slope += llp.second;
	      
	      followRiver(ll.first, ll.second, llp.second, pending, edges, direction_fine, mask_fine, outputNodes, outside, ignore);
	    }
	    
	    pending.pop();
	  }
	}

      Measure latitude(Inds::lat), longitude(Inds::lon);
      mask_coarse.calcLatitudeLongitude(rr, cc, latitude, longitude);
      
      HydroSurfaceNode* surface = new HydroSurfaceNode(mask_coarse.calcArea(rr, cc) * mask_coarse.getCellConst(rr, cc),
						       max(total_dist / paths, min_dist / 4), mask_coarse.calcDistance(rr - 1, cc - 1, rr + 1, cc + 1) / (2 * M_SQRT2),
						       total_slope / weight_slope, latitude, longitude);
      // divide edges weights by #paths
      surface->setEdges(edges, paths);
      return surface;
    }

    void mergeByLocation(vector<HydroOutputNode*>& outputNodes, vector<HydroOutputNode*>& tileOutputNodes, map<unsigned, HydroNode*>& surfaces_coarse) {
      // Adds new nodes that haven't been seen, and combines the inflows together for ones that have.
      for (vector<HydroOutputNode*>::const_iterator it = tileOutputNodes.begin(); it != tileOutputNodes.end(); it++) {
	// Check if this is in outputNodes
	bool found = false;
	for (vector<HydroOutputNode*>::const_iterator jt = outputNodes.begin(); jt != outputNodes.end(); jt++) {
	  if ((*it)->matchLocation(*jt)) {
	    HydroNode::replaceNode(*it, *jt, surfaces_coarse);
	    found = true;
	  }
	}

	if (!found)
	  outputNodes.push_back(*it);
      }
    }

    // generate a river out of this cell
    void generateRiver(Measure lat, Measure lon, map<unsigned, HydroNode*>& rivers, DInfinityMap& direction_fine, GeographicMap<bool>& mask_fine, GeographicMap<double>& slope_fine, const vector<HydroOutputNode*>& outputNodes, HydroOutputNode* outside, HydroOutputNode* ignore, double min_dist, double bigger = 0, uint recurses = 0) {
      if (recurses > 700) {
	// Longer than the Nile at 0.1 degrees
	return;
      }
      // cout << "Generating river at " << lat << ", " << lon << " (" << bigger << ") " << recurses << endl;
      rivers[mask_fine.getIndex(lat, lon)] = ignore; // temporary

      map<unsigned, pair<double, HydroNode*> > edges;
      double total_dist = 0, total_slope = 0, weight_slope = 0;

      unsigned rr = mask_coarse.getLatitudes().inRange(lat), cc = mask_coarse.getLongitudes().inRange(lon);
      bool offedge = false;

      // Follow this out of the cell
      queue< pair< pair<Measure, Measure>, double> > pending;
      pending.push(pair< pair<Measure, Measure>, double>(pair<Measure, Measure>(lat, lon), 1.0));

      while (!pending.empty()) {
        pair< pair<Measure, Measure>, double> llp = pending.front();
        pair<Measure, Measure> ll = llp.first;
        if (ll.first < mask_coarse.getLatitudes().getCellMin(rr) - mask_coarse.getLatitudes().getWidths() * bigger ||
            ll.first >= mask_coarse.getLatitudes().getCellMax(rr) + mask_coarse.getLatitudes().getWidths() * bigger ||
            ll.second < mask_coarse.getLongitudes().getCellMin(cc) - mask_coarse.getLongitudes().getWidths() * bigger ||
            ll.second >= mask_coarse.getLongitudes().getCellMax(cc) + mask_coarse.getLongitudes().getWidths() * bigger) {
          // is this the output node?
          if (mask_fine.getDouble(ll.first, ll.second) == 0)
            rivers[mask_fine.getIndex(ll.first, ll.second)] = outside;

          if (rivers.find(mask_fine.getIndex(ll.first, ll.second)) == rivers.end())
            generateRiver(ll.first, ll.second, rivers, direction_fine, mask_fine, slope_fine, outputNodes, outside, ignore, min_dist, bigger, recurses+1);

          addEdge(edges, mask_fine.getIndex(ll.first, ll.second), llp.second, rivers[mask_fine.getIndex(ll.first, ll.second)]);
        } else {
          total_dist += llp.second * mask_fine.calcCellSpan(lat, lon);
          total_slope += llp.second * slope_fine.getDouble(lat, lon);
          weight_slope += llp.second;

          bool riverOffedge = followRiver(ll.first, ll.second, llp.second, pending, edges, direction_fine, mask_fine, outputNodes, outside, ignore);
          offedge = offedge || riverOffedge;
        }

        pending.pop();
      }

      if (total_dist < min_dist && !offedge && bigger < 2) {
        //cout << "Total Dist: " << total_dist << endl;
        return generateRiver(lat, lon, rivers, direction_fine, mask_fine, slope_fine, outputNodes, outside, ignore, min_dist, bigger + 1, recurses+1);
      }
      if (total_dist < min_dist)
        total_dist = min_dist;

      // actually make the river and add it to rivers
      HydroNode* river = new HydroRiverNode(total_dist * mask_fine.calcCellSpan(lat, lon),
                                            total_dist, mask_fine.calcCellSpan(lat, lon),
                                            total_slope / weight_slope, lat, lon);

      river->setEdges(edges);
      rivers[mask_fine.getIndex(lat, lon)] = river;
    }

    void addEdge(map<unsigned, pair<double, HydroNode*> >& edges, unsigned index, double weight, HydroNode* target) {
      if (edges.find(index) == edges.end())
        edges[index] = pair<double, HydroNode*>(weight, target);
      else
        edges[index].first += weight;
    }

    // returns true if flows off edge
    bool followRiver(Measure lat, Measure lon, double weight, queue< pair< pair<Measure, Measure>, double> >& pending, map<unsigned, pair<double, HydroNode*> >& edges, DInfinityMap& direction_fine, GeographicMap<bool>& mask_fine, const vector<HydroOutputNode*>& outputNodes, HydroOutputNode* outside, HydroOutputNode* ignore) {
      if (weight < .01) {
        addEdge(edges, mask_fine.getIndex(lat, lon), weight, ignore);
        return false;
      }

      Measure lat0(Inds::lat), lon0(Inds::lon), lat1(Inds::lat), lon1(Inds::lon);
      double portion0;

      bool offedge = false;

      direction_fine.getDirections(lat, lon, lat0, lon0, lat1, lon1, portion0);
      if (lat == lat0 && lon == lon0 && lat == lat1 && lon == lon1)
	return false; // No direction: missing data

      bool make_fine_0, make_fine_1;
      try {
	make_fine_0 = mask_fine.getDouble(lat0, lon0);
      } catch (runtime_error& e) {
	make_fine_0 = false;
      }
      try {
	make_fine_1 = mask_fine.getDouble(lat1, lon1);
      } catch (runtime_error& e) {
	make_fine_1 = false;
      }
      
      if (portion0 > 0) {
        if (make_fine_0 == 0) {
          if (portion0 < 1)
            addEdge(edges, mask_fine.getIndex(lat, lon), portion0 * weight, ignore);
          else
            addEdge(edges, mask_fine.getIndex(lat, lon), portion0 * weight, outside);
          offedge = true;
        } else {
          if (lat0 >= mask_fine.getLatitudes().getMin() + mask_fine.getLatitudes().getWidths() &&
              lat0 < mask_fine.getLatitudes().getMax() - mask_fine.getLatitudes().getWidths() &&
              lon0 >= mask_fine.getLongitudes().getMin() + mask_fine.getLongitudes().getWidths() &&
              lon0 < mask_fine.getLongitudes().getMax() - mask_fine.getLongitudes().getWidths())
            pending.push(pair< pair<Measure, Measure>, double>(pair<Measure, Measure>(lat0, lon0), portion0 * weight));
          else {
            addEdge(edges, mask_fine.getIndex(lat, lon), portion0 * weight, outside);
            offedge = true;
          }
        }
      }
      if (portion0 < 1) {
        if (make_fine_1 == 0) {
          if (portion0 > 0)
            addEdge(edges, mask_fine.getIndex(lat, lon), (1 - portion0) * weight, ignore);
          else
            addEdge(edges, mask_fine.getIndex(lat, lon), (1 - portion0) * weight, outside);
          offedge = true;
        } else {
          if (lat1 >= mask_fine.getLatitudes().getMin() + mask_fine.getLatitudes().getWidths() &&
              lat1 < mask_fine.getLatitudes().getMax() - mask_fine.getLatitudes().getWidths() &&
              lon1 >= mask_fine.getLongitudes().getMin() + mask_fine.getLongitudes().getWidths() &&
              lon1 < mask_fine.getLongitudes().getMax() - mask_fine.getLongitudes().getWidths())
            pending.push(pair< pair<Measure, Measure>, double>(pair<Measure, Measure>(lat1, lon1), (1 - portion0) * weight));
          else {
            addEdge(edges, mask_fine.getIndex(lat, lon), (1 - portion0) * weight, outside);
            offedge = true;
          }
        }
      }

      return offedge;
    }

    // Serializable protocol

    friend void* nodeListConstructor(istream& in, PointerReference& reference);

    virtual istream& streamExtract(istream& in, PointerReference& reference) {
      unsigned surfaces_count;
      in >> surfaces_count;

      for (unsigned ii = 0; ii < surfaces_count; ii++) {
	unsigned index;
	in >> index;

	HydroNode* node = (HydroNode*) reference.streamExtractPointer(in, hydronodeConstructor);
	surfaces_coarse.insert(pair<unsigned, HydroNode*>(index, node));
      }

      return in;
    }

    virtual ostream& streamInsert(ostream& os, PointerTracker& tracker) const {
      os << surfaces_coarse.size() << " ";

      for (map<unsigned, HydroNode*>::const_iterator it = surfaces_coarse.begin() ; it != surfaces_coarse.end(); it++) {
	os << it->first << " ";
	it->second->streamInsertPointer(os, tracker);
      }

      return os;
    }

  };
}

#endif
