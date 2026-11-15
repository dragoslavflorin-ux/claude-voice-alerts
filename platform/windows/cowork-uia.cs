// Native UI Automation client (IUIAutomation from UIAutomationCore.dll, through COM) for the Cowork watcher.
// Why not System.Windows.Automation: its managed client leaks private memory on every cached read (B-03,
// about 100 MB per hour at one read every 1.5 s, GC does not recover it). Here every COM object is released
// explicitly right after use, and the cached tree is copied into plain Node objects
// (.Cached.Name, .Cached.ControlType.ProgrammaticName, .CachedChildren) that the PowerShell parser reads.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CvaUia {
    [ComImport, Guid("ff48dba4-60ef-4201-aa87-54103eef594e")] class CUIAutomation { }

    [ComImport, Guid("352ffba8-0973-437c-a61f-f64cafd81df9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationCondition { }

    [ComImport, Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomation {
        void _CompareElements(); void _CompareRuntimeIds(); void _GetRootElement();
        IUIAutomationElement ElementFromHandle(IntPtr hwnd);
        void _ElementFromPoint(); void _GetFocusedElement(); void _GetRootElementBuildCache();
        void _ElementFromHandleBuildCache(); void _ElementFromPointBuildCache(); void _GetFocusedElementBuildCache();
        void _CreateTreeWalker();
        void _get_ControlViewWalker(); void _get_ContentViewWalker();
        IUIAutomationTreeWalker get_RawViewWalker();
        IUIAutomationCondition get_RawViewCondition();
        void _get_ControlViewCondition(); void _get_ContentViewCondition();
        IUIAutomationCacheRequest CreateCacheRequest();
        void _CreateTrueCondition(); void _CreateFalseCondition();
        IUIAutomationCondition CreatePropertyCondition(int propertyId, [MarshalAs(UnmanagedType.Struct)] object value);
    }

    [ComImport, Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationElement {
        void _SetFocus(); void _GetRuntimeId(); void _FindFirst(); void _FindAll(); void _FindFirstBuildCache();
        IUIAutomationElementArray FindAllBuildCache(int scope, IUIAutomationCondition condition, IUIAutomationCacheRequest cacheRequest);
        IUIAutomationElement BuildUpdatedCache(IUIAutomationCacheRequest cacheRequest);
        [return: MarshalAs(UnmanagedType.Struct)] object GetCurrentPropertyValue(int propertyId);
        void _GetCurrentPropertyValueEx();
        [return: MarshalAs(UnmanagedType.Struct)] object GetCachedPropertyValue(int propertyId);
        void _GetCachedPropertyValueEx(); void _GetCurrentPatternAs(); void _GetCachedPatternAs();
        void _GetCurrentPattern(); void _GetCachedPattern(); void _GetCachedParent();
        IUIAutomationElementArray GetCachedChildren();
    }

    [ComImport, Guid("14314595-b4bc-4055-95f2-58f2e42c9855"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationElementArray {
        int get_Length();
        IUIAutomationElement GetElement(int index);
    }

    [ComImport, Guid("b32a92b5-bc25-4078-9c08-d7ee95c48e03"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationCacheRequest {
        void AddProperty(int propertyId);
        void _AddPattern(); void _Clone(); void _get_TreeScope();
        void put_TreeScope(int scope);
        void _get_TreeFilter();
        void put_TreeFilter(IUIAutomationCondition filter);
    }

    [ComImport, Guid("4042c624-389c-4afc-a630-9df854a541fc"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationTreeWalker {
        IUIAutomationElement GetParentElement(IUIAutomationElement element);
    }

    public class NodeType { public string ProgrammaticName; }
    public class NodeInfo { public string Name; public NodeType ControlType; }
    public class Node {
        public NodeInfo Cached = new NodeInfo();
        public Node[] CachedChildren = new Node[0];
    }

    public static class Reader {
        const int UIA_NamePropertyId = 30005, UIA_ControlTypePropertyId = 30003;
        const int UIA_ButtonControlTypeId = 50000, UIA_TextControlTypeId = 50020;
        const int TreeScope_Element = 1, TreeScope_Descendants = 4;
        const int MaxDepth = 24;
        static IUIAutomation uia;
        static IUIAutomationCacheRequest cr;
        static IUIAutomationElement sidebar;
        static List<IUIAutomationElement> candidates = new List<IUIAutomationElement>();
        static List<IUIAutomationElement> ancestors = new List<IUIAutomationElement>();
        static readonly Dictionary<int, NodeType> types = new Dictionary<int, NodeType>();

        static void Rel(object o) { if (o != null && Marshal.IsComObject(o)) Marshal.FinalReleaseComObject(o); }
        static void RelAll(List<IUIAutomationElement> l) { foreach (var e in l) Rel(e); l.Clear(); }

        static void Init() {
            if (uia != null) return;
            uia = (IUIAutomation)new CUIAutomation();
            cr = uia.CreateCacheRequest();
            cr.AddProperty(UIA_NamePropertyId); cr.AddProperty(UIA_ControlTypePropertyId);
            cr.put_TreeScope(TreeScope_Element | TreeScope_Descendants);
            IUIAutomationCondition raw = uia.get_RawViewCondition();
            cr.put_TreeFilter(raw); Rel(raw);
        }

        // names as in System.Windows.Automation ("ControlType.Button"), from the UIA control type ids
        static readonly string[] typeNames = { "Button", "Calendar", "CheckBox", "ComboBox", "Edit", "Hyperlink", "Image",
            "ListItem", "List", "Menu", "MenuBar", "MenuItem", "ProgressBar", "RadioButton", "ScrollBar", "Slider",
            "Spinner", "StatusBar", "Tab", "TabItem", "Text", "ToolBar", "ToolTip", "Tree", "TreeItem", "Custom",
            "Group", "Thumb", "DataGrid", "DataItem", "Document", "SplitButton", "Window", "Pane", "Header",
            "HeaderItem", "Table", "TitleBar", "Separator", "SemanticZoom", "AppBar" };
        static NodeType TypeOf(int id) {
            NodeType t;
            if (types.TryGetValue(id, out t)) return t;
            int i = id - 50000;
            t = new NodeType { ProgrammaticName = "ControlType." + ((i >= 0 && i < typeNames.Length) ? typeNames[i] : id.ToString()) };
            types[id] = t; return t;
        }

        // copies the cached subtree of e into Nodes, releasing every COM object it touches (not e itself)
        static Node Copy(IUIAutomationElement e, int depth) {
            Node n = new Node();
            object name = e.GetCachedPropertyValue(UIA_NamePropertyId);
            object ct = e.GetCachedPropertyValue(UIA_ControlTypePropertyId);
            n.Cached.Name = name as string ?? "";
            n.Cached.ControlType = TypeOf((ct is int) ? (int)ct : 0);
            if (depth >= MaxDepth) return n;
            IUIAutomationElementArray kids = e.GetCachedChildren();
            if (kids != null) {
                try {
                    int len = kids.get_Length();
                    Node[] arr = new Node[len];
                    for (int i = 0; i < len; i++) {
                        IUIAutomationElement k = kids.GetElement(i);
                        try { arr[i] = Copy(k, depth + 1); } finally { Rel(k); }
                    }
                    n.CachedChildren = arr;
                } finally { Rel(kids); }
            }
            return n;
        }

        static Node Snapshot(IUIAutomationElement e) {
            IUIAutomationElement c = null;
            try { c = e.BuildUpdatedCache(cr); return Copy(c, 0); } finally { Rel(c); }
        }

        // Finding the list (rare: at start and when the app reloads). Step 1: every button of the window,
        // with its subtree, so the PowerShell parser can tell which one is a conversation row.
        public static Node[] FindButtons(IntPtr hwnd) {
            Init(); RelAll(candidates); RelAll(ancestors);
            IUIAutomationElement root = null; IUIAutomationCondition cond = null; IUIAutomationElementArray arr = null;
            try {
                root = uia.ElementFromHandle(hwnd);
                cond = uia.CreatePropertyCondition(UIA_ControlTypePropertyId, UIA_ButtonControlTypeId);
                arr = root.FindAllBuildCache(TreeScope_Descendants, cond, cr);
                if (arr == null) return new Node[0];
                int len = arr.get_Length();
                Node[] res = new Node[len];
                for (int i = 0; i < len; i++) {
                    IUIAutomationElement e = arr.GetElement(i);
                    candidates.Add(e);
                    res[i] = Copy(e, 0);
                }
                return res;
            } finally { Rel(arr); Rel(cond); Rel(root); }
        }

        // a button under a Text is a section header or the rename button of the open conversation
        public static bool ParentIsText(int index) {
            IUIAutomationTreeWalker w = uia.get_RawViewWalker(); IUIAutomationElement p = null;
            try {
                p = w.GetParentElement(candidates[index]);
                if (p == null) return false;
                object ct = p.GetCurrentPropertyValue(UIA_ControlTypePropertyId);
                return (ct is int) && (int)ct == UIA_TextControlTypeId;
            } finally { Rel(p); Rel(w); }
        }

        // Step 2: the ancestors of a row button (parent first), each with its subtree
        public static Node[] Ancestors(int index, int levels) {
            RelAll(ancestors);
            IUIAutomationTreeWalker w = uia.get_RawViewWalker();
            List<Node> res = new List<Node>();
            try {
                IUIAutomationElement cur = w.GetParentElement(candidates[index]);
                while (cur != null && res.Count < levels) {
                    ancestors.Add(cur);
                    res.Add(Snapshot(cur));
                    cur = w.GetParentElement(cur);
                }
                Rel(cur);
            } finally { Rel(w); RelAll(candidates); }
            return res.ToArray();
        }

        // Step 3: keep one ancestor as the list; everything else is released
        public static void Select(int ancestorIndex) {
            Rel(sidebar); sidebar = null;
            if (ancestorIndex >= 0 && ancestorIndex < ancestors.Count) { sidebar = ancestors[ancestorIndex]; ancestors.RemoveAt(ancestorIndex); }
            RelAll(ancestors); RelAll(candidates);
        }

        public static bool HasList { get { return sidebar != null; } }
        public static void Reset() { Rel(sidebar); sidebar = null; RelAll(ancestors); RelAll(candidates); }

        // one read of the list kept by Select; null when it cannot be read now (the list is then forgotten)
        public static Node Read() {
            if (sidebar == null) return null;
            try { return Snapshot(sidebar); }
            catch { Reset(); return null; }
        }
    }
}
