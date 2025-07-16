# This class defines the failure type for contract violations related to
# input data streams. When the Bash orchestrator provides a malformed or
# incomplete stream, this is the specific exception that will be thrown.
# It clearly distinguishes a data integrity problem from a user invocation error.

package GitReport::Exception::InputData;

# We are building another Moo-based class.
use Moo;

# As with its sibling, this class does its work through composition. It consumes
# the universal exception contract, inheriting its structure and safety.
# Its existence allows for granular error handling:
#
#   try { ... }
#   catch {
#       if ($_->isa('GitReport::Exception::Invocation')) { ... }
#       if ($_->isa('GitReport::Exception::InputData'))  { ... }
#   };
#
# This makes our error handling logic clean, readable, and robust.
with 'GitReport::Exception';

# This specific failure type is now defined and ready to guard our data contracts.
1;
