using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Web.Script.Serialization;

namespace PCMigration
{
    /// <summary>Thin JSON helpers over the in-box JavaScriptSerializer (no NuGet, so the exe stays a single file).</summary>
    public static class Json
    {
        private static JavaScriptSerializer S() { return new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 64 }; }
        public static object Parse(string text) { return S().DeserializeObject(text); }
        public static Dictionary<string, object> ParseObject(string text) { return Parse(text) as Dictionary<string, object> ?? new Dictionary<string, object>(); }
        public static string Serialize(object o) { return S().Serialize(o); }

        public static Dictionary<string, object> Obj(object o, string key) { var d = o as IDictionary<string, object>; object v; return d != null && d.TryGetValue(key, out v) ? v as Dictionary<string, object> : null; }
        public static IList<object> Arr(object o, string key)
        {
            var d = o as IDictionary<string, object>; object v;
            if (d == null || !d.TryGetValue(key, out v) || v == null) return new List<object>();
            if (v is object[]) return (object[])v;
            if (v is ArrayList) { var l = new List<object>(); foreach (var x in (ArrayList)v) l.Add(x); return l; }
            if (v is IEnumerable && !(v is string)) { var l = new List<object>(); foreach (var x in (IEnumerable)v) l.Add(x); return l; }
            return new List<object> { v };
        }
        public static string Str(object o, string key, string def = "") { var d = o as IDictionary<string, object>; object v; return d != null && d.TryGetValue(key, out v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : def; }
        public static bool Bool(object o, string key, bool def = false)
        {
            var d = o as IDictionary<string, object>; object v;
            if (d == null || !d.TryGetValue(key, out v) || v == null) return def;
            if (v is bool) return (bool)v;
            var s = Convert.ToString(v, CultureInfo.InvariantCulture); return s == "1" || string.Equals(s, "true", StringComparison.OrdinalIgnoreCase);
        }
        public static double Num(object o, string key, double def = 0)
        {
            var d = o as IDictionary<string, object>; object v;
            if (d == null || !d.TryGetValue(key, out v) || v == null) return def;
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch { return def; }
        }
        public static double? NumOrNull(object o, string key) { var d = o as IDictionary<string, object>; object v; if (d == null || !d.TryGetValue(key, out v) || v == null) return null; try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch { return null; } }
        public static DateTime? Date(object o, string key) { var s = Str(o, key); DateTime t; return DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out t) ? t.ToLocalTime() : (DateTime?)null; }
    }
}
