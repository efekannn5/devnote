// SF Symbols yalnızca Apple platformlarında kullanılabilir (lisans). Windows'ta aynı anlamdaki
// Lucide ikonları kullanılır; defterlerde kayıtlı SF adı buradan eşlenir.

import {
  Airplay, AlignLeft, ArrowDown, ArrowUp, Bell, Bold, Book, Briefcase, Check, CheckCircle2, ChevronDown,
  ChevronRight, Circle, Cloud, CloudOff, Code, Copy, Eraser, FileText, Flag, FolderPlus, GraduationCap,
  Grip, Hammer, Heart, Highlighter, Image, Inbox, IndentDecrease, IndentIncrease, Italic, Leaf, Lightbulb,
  Link, List, ListChecks, ListOrdered, Lock, MessageSquare, Minus, MoreHorizontal, Palette, Pencil, Pin,
  PinOff, Plane, Plus, Quote, RefreshCw, Repeat, Search, Settings, Share2, ShoppingCart, Sparkles,
  SquareDashed, SquarePen, SquareTerminal, Star, Strikethrough, Trash2, Type, Underline, User, UserCheck,
  UserPlus, Users, X, Zap, Heading1, Heading2, Heading3, AlertTriangle, ScrollText, Ban, Baseline,
  type LucideIcon,
} from 'lucide-react'

const SF: Record<string, LucideIcon> = {
  'book.closed.fill': Book,
  'hammer.fill': Hammer,
  'heart.fill': Heart,
  'lightbulb.fill': Lightbulb,
  'briefcase.fill': Briefcase,
  'graduationcap.fill': GraduationCap,
  'person.2.fill': Users,
  'star.fill': Star,
  'flag.fill': Flag,
  'leaf.fill': Leaf,
  'cart.fill': ShoppingCart,
  airplane: Plane,
  'terminal.fill': SquareTerminal,
  'paintpalette.fill': Palette,
  'tray.full.fill': Inbox,
  'pin.fill': Pin,
  checklist: ListChecks,
  'person.crop.circle.badge.checkmark': UserCheck,
  sparkles: Sparkles,
}

export function SFIcon({ name, size = 16, color, strokeWidth = 2, fill }: { name: string; size?: number; color?: string; strokeWidth?: number; fill?: boolean }) {
  const Icon = SF[name] ?? Book
  return <Icon size={size} color={color} strokeWidth={strokeWidth} fill={fill ? color ?? 'currentColor' : 'none'} fillOpacity={fill ? 0.18 : 0} />
}

export const NOTEBOOK_ICONS = [
  'book.closed.fill', 'hammer.fill', 'heart.fill', 'lightbulb.fill', 'briefcase.fill',
  'graduationcap.fill', 'person.2.fill', 'star.fill', 'flag.fill', 'leaf.fill',
  'cart.fill', 'airplane', 'terminal.fill', 'paintpalette.fill',
]

export const KIND_ICONS: Record<string, LucideIcon> = {
  text: Type,
  heading: Heading1,
  heading2: Heading2,
  heading3: Heading3,
  checklist: ListChecks,
  bullet: List,
  numbered: ListOrdered,
  quote: Quote,
  code: Code,
  divider: Minus,
  image: Image,
}

export {
  Airplay, AlignLeft, ArrowDown, ArrowUp, Bell, Bold, Check, CheckCircle2, ChevronDown, ChevronRight, Circle,
  Cloud, CloudOff, Code, Copy, Eraser, FileText, FolderPlus, Grip, Highlighter, Image, IndentDecrease,
  IndentIncrease, Italic, Link, List, Lock, MessageSquare, Minus, MoreHorizontal, Palette, Pencil, Pin, PinOff,
  Plus, RefreshCw, Repeat, Search, Settings, Share2, Sparkles, SquareDashed, SquarePen, Strikethrough, Trash2,
  Underline, User, UserPlus, Users, X, Zap, AlertTriangle, ScrollText, Ban, Baseline,
}
