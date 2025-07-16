# This file defines a specific, named category of failure: an error in how
# the user invoked the application. Its purpose is to give a precise type to
# a class of problems related to command-line usage, allowing the main
# application to handle such errors distinctly from other failure modes.

package GitReport::Exception::Invocation;

# This declares that we are building a standard Moo-based class.
use Moo;

# This is the single, most powerful line in the file. With it, this class
# consumes the GitReport::Exception role. It instantly and effortlessly
# inherits the entire contract: the required 'message' and 'exit_code'
# attributes, along with their immutability and type-safety guarantees.
#
# No code is duplicated. The behavior is composed. The purpose of this class
# is now its *type*, providing semantic context to any failure it represents.
with 'GitReport::Exception';

# The specific failure type is now defined and ready for use.
1;
