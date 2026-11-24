#ifndef CONSTANT_HYDRO_FORCING_H
#define CONSTANT_HYDRO_FORCING_H

namespace openworld {

class ConstantForcing : public HydroForcing {
private:
  double precipValue;
  double meltValue;
  unsigned numDays;

public:
  /// @param precipRunoff Uniform precipitation runoff value for all nodes
  /// @param meltRunoff   Uniform snow/ice melt runoff value for all nodes
  /// @param days         Number of valid days (defaults to 1)
  ConstantForcing(double precipRunoff = 1.0, double meltRunoff = 1.0, unsigned days = 1)
    : precipValue(precipRunoff), meltValue(meltRunoff), numDays(days) {}

  virtual unsigned days() const override {
    return numDays;
  }

  virtual double precipRunoff(HydroNode* /*node*/, unsigned day) override {
    if (day >= numDays)
      return 0.0;
    return precipValue;
  }

  virtual double meltRunoff(HydroNode* /*node*/, unsigned day) override {
    if (day >= numDays)
      return 0.0;
    return meltValue;
  }
};

} // namespace openworld

#endif // CONSTANT_HYDRO_FORCING_H
