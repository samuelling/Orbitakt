import Foundation

/// One satellite's orbit, ready to propagate.
///
/// This is Vallado's SGP4 (the model the TLEs are fitted to; WGS-72 constants, "improved"
/// mode) for near-Earth orbits. A Python mirror of this exact code reproduces the reference
/// implementation to within 1e-9 km on the AFSPC verification set.
///
/// High orbits (period ≥ 225 min: GPS, Galileo, the geostationary belt) run through the same
/// equations without SDP4's lunar-solar terms. Over the few days a TLE is used for, that stays
/// within about 0.04° of the full model as seen from Earth for near-circular orbits, which is
/// all a rhythm needs. Highly eccentric high orbits drift too much without those terms, so the
/// catalog leaves them out (`isUsable`).
struct SGP4 {
    // WGS-72
    static let mu = 398_600.8
    static let re = 6378.135
    static let xke = 60.0 / (re * re * re / mu).squareRoot()
    static let j2 = 0.001082616
    static let j3 = -0.00000253881
    static let j4 = -0.00000165597
    static let j3oj2 = j3 / j2
    private static let twoPi = 2 * Double.pi
    private static let x2o3 = 2.0 / 3.0

    let epoch: TimeInterval            // Unix seconds
    let periodMinutes: Double
    let eccentricity: Double
    let inclination: Double            // radians

    private let bstar, ecco, inclo, nodeo, argpo, mo, no: Double
    private let mdot, argpdot, nodedot, omgcof, xmcof, nodecf, t2cof, xlcof, aycof: Double
    private let delmo, sinmao, x7thm1, con41, x1mth2, cosio, sinio: Double
    private let cc1, cc4, cc5, eta: Double
    private let d2, d3, d4, t3cof, t4cof, t5cof: Double
    private let isimp: Bool

    /// Usable for sky positions: near-Earth, or a high orbit that is close to circular.
    var isUsable: Bool { periodMinutes < 225 || eccentricity < 0.1 }

    /// Angles in radians, mean motion in radians per minute (Kozai, as in the TLE).
    init(epoch: TimeInterval, bstar: Double, ecc: Double, incl: Double, node: Double,
         argp: Double, meanAnomaly: Double, meanMotion noKozai: Double) {
        let re = SGP4.re, xke = SGP4.xke, j2 = SGP4.j2, j4 = SGP4.j4, j3oj2 = SGP4.j3oj2
        let x2o3 = SGP4.x2o3
        self.epoch = epoch
        self.bstar = bstar
        ecco = ecc
        inclo = incl
        nodeo = node
        argpo = argp
        mo = meanAnomaly
        eccentricity = ecc
        inclination = incl

        // initl: recover the original mean motion and semi-major axis
        let eccsq = ecc * ecc
        let omeosq = 1 - eccsq
        let rteosq = omeosq.squareRoot()
        let cosio = cos(incl)
        let cosio2 = cosio * cosio
        let ak = pow(xke / noKozai, x2o3)
        let d1 = 0.75 * j2 * (3 * cosio2 - 1) / (rteosq * omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1 - del * del - del * (1.0 / 3.0 + 134 * del * del / 81))
        del = d1 / (adel * adel)
        let no = noKozai / (1 + del)
        let ao = pow(xke / no, x2o3)
        let sinio = sin(incl)
        let po = ao * omeosq
        let con42 = 1 - 5 * cosio2
        let con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1 - ecc)
        self.no = no
        self.cosio = cosio
        self.sinio = sinio
        self.con41 = con41
        periodMinutes = SGP4.twoPi / no

        // sgp4init (near-Earth)
        let ss = 78.0 / re + 1
        let qzms2t = pow((120.0 - 78.0) / re, 4)
        // Low perigee, or a deep-space orbit (as the reference does): skip the higher drag terms
        let simple = rp < (220.0 / re + 1) || SGP4.twoPi / no >= 225
        isimp = simple
        var sfour = ss
        var qzms24 = qzms2t
        let perige = (rp - 1) * re
        if perige < 156 {
            sfour = perige - 78
            if perige < 98 { sfour = 20 }
            qzms24 = pow((120 - sfour) / re, 4)
            sfour = sfour / re + 1
        }
        let pinvsq = 1 / posq
        let tsi = 1 / (ao - sfour)
        let eta = ao * ecc * tsi
        let etasq = eta * eta
        let eeta = ecc * eta
        let psisq = abs(1 - etasq)
        let coef = qzms24 * pow(tsi, 4)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * no * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq))
            + 0.375 * j2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)))
        let cc1 = bstar * cc2
        var cc3 = 0.0
        if ecc > 1e-4 { cc3 = -2 * coef * tsi * j3oj2 * no * sinio / ecc }
        let x1mth2 = 1 - cosio2
        let cc4a = eta * (2 + 0.5 * etasq) + ecc * (0.5 + 2 * etasq)
        let cc4b = -3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta))
        let cc4c = 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * argp)
        let cc4 = 2 * no * coef1 * ao * omeosq * (cc4a - j2 * tsi / (ao * psisq) * (cc4b + cc4c))
        let cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq)
        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * j2 * pinvsq * no
        let temp2 = 0.5 * temp1 * j2 * pinvsq
        let temp3 = -0.46875 * j4 * pinvsq * pinvsq * no
        mdot = no + 0.5 * temp1 * rteosq * con41
            + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4)
        argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4)
            + temp3 * (3 - 36 * cosio2 + 49 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio
        omgcof = bstar * cc3 * cos(argp)
        xmcof = ecc > 1e-4 ? -x2o3 * coef * bstar / eeta : 0
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1
        if abs(cosio + 1) > 1.5e-12 {
            xlcof = -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / (1 + cosio)
        } else {
            xlcof = -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / 1.5e-12
        }
        aycof = -0.5 * j3oj2 * sinio
        let dm = 1 + eta * cos(meanAnomaly)
        delmo = dm * dm * dm
        sinmao = sin(meanAnomaly)
        x7thm1 = 7 * cosio2 - 1
        self.x1mth2 = x1mth2
        self.cc1 = cc1
        self.cc4 = cc4
        self.cc5 = cc5
        self.eta = eta
        if !simple {
            let cc1sq = cc1 * cc1
            let d2 = 4 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3
            let d3 = (17 * ao + sfour) * temp
            let d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1
            self.d2 = d2
            self.d3 = d3
            self.d4 = d4
            t3cof = d2 + 2 * cc1sq
            t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq))
            t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq))
        } else {
            d2 = 0; d3 = 0; d4 = 0; t3cof = 0; t4cof = 0; t5cof = 0
        }
    }

    /// Position in the TEME frame (km) at `t` minutes after epoch, or nil if the model fails
    /// (the object has decayed, or the elements are too old to mean anything).
    func position(minutes t: Double) -> (x: Double, y: Double, z: Double)? {
        let twoPi = SGP4.twoPi
        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf
        var mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2
        if !isimp {
            let delomg = omgcof * t
            let dm = 1 + eta * cos(xmdf)
            let delm = xmcof * (dm * dm * dm - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t
            let t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe = tempe + bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + t * t5cof)
        }
        guard no > 0 else { return nil }
        let am = pow(SGP4.xke / no, SGP4.x2o3) * tempa * tempa
        var em = ecco - tempe
        guard em < 1, em >= -0.001, am >= 0.95 else { return nil }
        if em < 1e-6 { em = 1e-6 }
        mm = mm + no * templ
        var xlm = mm + argpm + nodem
        nodem = fmod(nodem, twoPi)
        argpm = fmod(argpm, twoPi)
        xlm = fmod(xlm, twoPi)
        mm = fmod(xlm - argpm - nodem, twoPi)

        // Long-period periodics
        let axnl = em * cos(argpm)
        var temp = 1 / (am * (1 - em * em))
        let aynl = em * sin(argpm) + temp * aycof
        let xl = mm + argpm + nodem + temp * xlcof * axnl

        // Kepler's equation
        let u = fmod(xl - nodem, twoPi)
        var eo1 = u
        var tem5 = 9999.9
        var ktr = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1e-12 && ktr <= 10 {
            sineo1 = sin(eo1)
            coseo1 = cos(eo1)
            tem5 = 1 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }

        // Short-period periodics
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1 - el2)
        guard pl >= 0 else { return nil }
        let rl = am * (1 - ecose)
        let betal = (1 - el2).squareRoot()
        temp = esine / (1 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1 - 2 * sinu * sinu
        temp = 1 / pl
        let temp1 = 0.5 * SGP4.j2 * temp
        let temp2 = temp1 * temp
        let mrt = rl * (1 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        su = su - 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodem + 1.5 * temp2 * cosio * sin2u
        let xinc = inclo + 1.5 * temp2 * cosio * sinio * cos2u
        guard mrt >= 1 else { return nil }

        let sinsu = sin(su), cossu = cos(su)
        let snod = sin(xnode), cnod = cos(xnode)
        let sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let r = mrt * SGP4.re
        return (r * (xmx * sinsu + cnod * cossu),
                r * (xmy * sinsu + snod * cossu),
                r * (sini * sinsu))
    }

    func position(at date: TimeInterval) -> (x: Double, y: Double, z: Double)? {
        position(minutes: (date - epoch) / 60)
    }
}

// MARK: - TLE parsing

extension SGP4 {
    /// Parse the two element lines of a TLE (the name line is handled by the caller).
    init?(line1 l1: String, line2 l2: String) {
        let a = Array(l1.utf8), b = Array(l2.utf8)
        guard a.count >= 63, b.count >= 63, a[0] == UInt8(ascii: "1"), b[0] == UInt8(ascii: "2")
        else { return nil }
        func field(_ s: [UInt8], _ lo: Int, _ hi: Int) -> String {
            String(decoding: s[lo..<min(hi, s.count)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        func num(_ s: [UInt8], _ lo: Int, _ hi: Int) -> Double? { Double(field(s, lo, hi)) }
        /// TLE "assumed decimal" exponent field, e.g. " 12345-3" = 0.12345e-3.
        func expo(_ s: [UInt8], _ lo: Int, _ hi: Int) -> Double? {
            var f = field(s, lo, hi)
            if f.isEmpty { return 0 }
            var sign = 1.0
            if f.hasPrefix("-") { sign = -1; f.removeFirst() } else if f.hasPrefix("+") { f.removeFirst() }
            guard f.count >= 3 else { return 0 }
            let mant = f.dropLast(2)
            let ex = f.suffix(2)
            guard let m = Double("0." + mant), let e = Double(ex) else { return nil }
            return sign * m * pow(10, e)
        }
        guard let yy = Int(field(a, 18, 20)), let doy = num(a, 20, 32),
              let bstar = expo(a, 53, 61),
              let incl = num(b, 8, 16), let node = num(b, 17, 25),
              let ecc = Double("0." + field(b, 26, 33)),
              let argp = num(b, 34, 42), let ma = num(b, 43, 51), let n = num(b, 52, 63),
              n > 0
        else { return nil }
        let year = yy < 57 ? 2000 + yy : 1900 + yy
        var comps = DateComponents()
        comps.year = year
        comps.month = 1
        comps.day = 1
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let jan1 = cal.date(from: comps) else { return nil }
        let deg = Double.pi / 180
        self.init(epoch: jan1.timeIntervalSince1970 + (doy - 1) * 86_400,
                  bstar: bstar, ecc: ecc, incl: incl * deg, node: node * deg,
                  argp: argp * deg, meanAnomaly: ma * deg, meanMotion: n * 2 * Double.pi / 1440)
    }
}

// MARK: - Where it is in your sky

/// An observer on the WGS-84 ellipsoid, with the rotation to local east/north/up.
struct Observer {
    let x, y, z: Double
    private let sphi, cphi, slam, clam: Double

    init(lat: Double, lon: Double, heightKm: Double = 0) {
        let a = 6378.137, f = 1 / 298.257223563
        let e2 = f * (2 - f)
        let phi = lat * .pi / 180, lam = lon * .pi / 180
        sphi = sin(phi); cphi = cos(phi); slam = sin(lam); clam = cos(lam)
        let n = a / (1 - e2 * sphi * sphi).squareRoot()
        x = (n + heightKm) * cphi * clam
        y = (n + heightKm) * cphi * slam
        z = (n * (1 - e2) + heightKm) * sphi
    }

    /// Azimuth (degrees clockwise from north, 0..<360) and elevation (degrees) of a TEME
    /// position, given Greenwich mean sidereal time (radians). Polar motion is ignored.
    @inline(__always)
    func look(_ r: (x: Double, y: Double, z: Double), gmst g: Double) -> (az: Double, el: Double) {
        let cg = cos(g), sg = sin(g)
        let ex = cg * r.x + sg * r.y
        let ey = -sg * r.x + cg * r.y
        let dx = ex - x, dy = ey - y, dz = r.z - z
        let e = -slam * dx + clam * dy
        let n = -sphi * clam * dx - sphi * slam * dy + cphi * dz
        let u = cphi * clam * dx + cphi * slam * dy + sphi * dz
        let el = atan2(u, (e * e + n * n).squareRoot()) * 180 / .pi
        var az = atan2(e, n) * 180 / .pi
        if az < 0 { az += 360 }
        return (az, el)
    }
}

enum Sidereal {
    /// Greenwich mean sidereal time (IAU-82, radians) for a Unix time, taking UT1 ≈ UTC.
    static func gmst(_ unix: TimeInterval) -> Double {
        let jd = unix / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545) / 36_525
        var s = -6.2e-6 * t * t * t + 0.093104 * t * t
            + (876_600 * 3600 + 8_640_184.812866) * t + 67_310.54841
        s = fmod(s * Double.pi / 180 / 240, 2 * Double.pi)
        return s < 0 ? s + 2 * Double.pi : s
    }
}
