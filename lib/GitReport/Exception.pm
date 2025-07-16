# This file defines the central, abstract contract for all application-specific
# failures. It is not a class, but a 'Role'—a set of capabilities and guarantees
# that concrete exception classes will promise to uphold. It is the very soul
# of our error handling strategy, ensuring consistency and predictability.

package GitReport::Exception;

# By choosing Moo::Role, we opt for composition over inheritance. This is a
# foundational architectural decision. Instead of a rigid 'is-a' relationship,
# we create a flexible 'can-do' contract, defining the DNA of an exception
# without dictating its specific form.
use Moo::Role;

# We import type constraints to bring rigor to our data definitions. This is a
# proactive measure against a common class of runtime errors, ensuring that the
# data carried by our exceptions is always of the expected type.
use Types::Standard qw(Str Int);

# -- The Immutable Contract --
# Each attribute below represents a non-negotiable guarantee provided by any
# class that consumes this role.

has message => (
    # is => 'ro' (read-only)
    # This forges an immutable contract. An exception, once created, represents a
    # fixed point of failure; its state must not be altered. This guarantees
    # stability and prevents downstream logic from corrupting the error report.
    is       => 'ro',

    # isa => Str
    # Enforces type safety at the attribute level. This is a compile-time
    # promise that this attribute will always contain a string.
    isa      => Str,

    # required => 1
    # It is impossible to construct a partial, invalid exception. This ensures
    # that every exception object is semantically complete upon instantiation.
    # There can be no failure without an explanation.
    required => 1,
);

has exit_code => (
    # is => 'ro'
    # The exit code is also immutable, ensuring the application's signal to the
    # outside world (e.g., a CI/CD system) is reliable and cannot be changed
    # after the failure has been established.
    is       => 'ro',

    # isa => Int
    # Guarantees the exit code is always an integer, fulfilling the contract
    # expected by shells and other calling processes.
    isa      => Int,

    # required => 1
    # Every defined failure type MUST be mapped to a specific exit code from
    # the ICD. This makes every failure a predictable, machine-readable event.
    required => 1,
);

# The contract is sealed. This module is now ready to empower other classes.
1;
